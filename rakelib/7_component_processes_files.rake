require "ruby_llm"
require "json"
require "kot_utils"

QUIET = %w[1 true yes].include?(ENV["QUIET"]&.downcase) unless defined?(QUIET)

COMP_PROCESSES_PROMPT_FILE = "raw/prompts/map_processes.txt"
COMP_PROCESSES_MODEL = ENV["COMP_PROCESSES_MODEL"] || "claude-sonnet-4-5"

# Z.ai Anthropic endpoint: uses Bearer auth instead of x-api-key
RubyLLM.configure do |config|
  config.anthropic_api_key = ENV.fetch("Z_API_KEY")
  config.anthropic_api_base = "https://api.z.ai/api/anthropic"
end

module ZaiAuthPatch
  def headers
    super
      .reject { |k, _| k.to_s.downcase == "x-api-key" }
      .merge("Authorization" => "Bearer #{RubyLLM.config.anthropic_api_key}")
  end
end

begin
  RubyLLM::Providers::Anthropic::Connection.prepend(ZaiAuthPatch)
rescue NameError
  RubyLLM::Providers::Anthropic.prepend(ZaiAuthPatch)
end

def strip_json_fences(text)
  text = text.strip
  text = text.sub(/\A```(?:json)?\s*\n?/, "").sub(/\n?\s*```\z/, "") if text.start_with?("```")
  text
end

VALID_PROCESS_IDS = File.foreach(PROCESSES_DICT)
  .map { |line| JSON.parse(line)["process_id"] }
  .to_a
  .freeze

VALIDATE_COMP_PROCESSES = ->(parsed_json, component_id) {
  mappings = parsed_json.is_a?(Array) ? parsed_json : parsed_json["processes"]
  raise "Expected a JSON array" unless mappings.is_a?(Array)

  # Empty array is valid for infrastructure components
  return mappings if mappings.empty?

  seen_ids = []

  mappings.each_with_index do |m, i|
    %w[process_id relevance].each do |key|
      raise "Missing '#{key}' at index #{i}" unless m.key?(key)
    end

    pid = m["process_id"]
    unless VALID_PROCESS_IDS.include?(pid)
      raise "Unknown process_id '#{pid}' at index #{i}. Must be one of the catalogue IDs."
    end
    raise "Duplicate process_id '#{pid}' at index #{i}" if seen_ids.include?(pid)
    seen_ids << pid

    relevance = m["relevance"].to_s
    raise "Chinese characters in relevance at index #{i}" if relevance.match?(/\p{Han}/)
    raise "Invalid foreign characters in relevance at index #{i}" if relevance.match?(/(?!\p{Cyrillic}|\p{Latin})\p{L}/)
    raise "Relevance too short at index #{i}" if relevance.size < 20
  end

  mappings
}

EXTRACT_COMP_PROCESSES = ->(cid, aggregates_path, prompt_path, target_path) {
  err_file = "#{target_path}.err"

  component_entry = File.foreach(COMPONENTS_FILE)
    .map { |line| JSON.parse(line) }
    .find { |c| c["ID"] == cid }

  unless component_entry
    warn "[SKIP] #{cid}: Not found in components catalog"
    return
  end

  aggregates_content = File.read(aggregates_path, encoding: "UTF-8")
  processes_content = File.read(PROCESSES_DICT, encoding: "UTF-8")
  user_prompt_template = File.read(prompt_path, encoding: "UTF-8")

  user_prompt = user_prompt_template % {component_id: cid}
  user_prompt += "\n\n### ОПИСАНИЕ КОМПОНЕНТА:\n#{component_entry.to_json}"
  user_prompt += "\n\n### ДОМЕННАЯ МОДЕЛЬ (АГРЕГАТЫ):\n#{aggregates_content}"
  user_prompt += "\n\n### КАТАЛОГ ПРОЦЕССОВ:\n#{processes_content}"

  system_prompt = %(
    You are an experienced business analyst and domain architect with deep knowledge of Russian Arbitration Court processes. You write in fluent and correct technical Russian only, except for technical terms.
  ).strip

  temperature = 0.2
  max_retries = 3

  unless QUIET
    warn "[#{cid}] model=#{COMP_PROCESSES_MODEL} temp=#{temperature} prompt=#{user_prompt.size} chars"
  end

  chat = RubyLLM.chat(
    model: COMP_PROCESSES_MODEL,
    provider: :anthropic,
    assume_model_exists: true
  ).with_instructions(system_prompt)
    .with_temperature(temperature)

  attempts = 0
  valid_mappings = nil
  last_error = nil
  last_error_class = nil

  while attempts < max_retries && !valid_mappings
    attempts += 1
    begin
      t0 = Time.now
      msg = if attempts == 1
        warn "[#{cid}] Submitting to LLM (attempt 1/#{max_retries})..." unless QUIET
        chat.ask(user_prompt)
      else
        warn "[#{cid}] Retry #{attempts}/#{max_retries} — #{last_error}" unless QUIET
        chat.ask("Your previous response failed schema validation: #{last_error}. Please correct your output and return ONLY the valid JSON array.")
      end
      elapsed = (Time.now - t0).round(1)

      raw = msg.content.dup.force_encoding("UTF-8")
      warn "[#{cid}] Response received (#{elapsed}s, #{raw.size} chars). Validating..." unless QUIET
      parsed_json = JSON.parse(strip_json_fences(raw))
      valid_mappings = VALIDATE_COMP_PROCESSES.call(parsed_json, cid)
    rescue JSON::ParserError, RuntimeError => e
      last_error = e.message
      last_error_class = e.class.name
      warn "[#{cid}] Validation failed: #{last_error}" unless QUIET
    rescue RubyLLM::Error => e
      last_error = e.message
      last_error_class = e.class.name
      warn "[#{cid}] LLM error (#{last_error_class}): #{last_error}" unless QUIET
    end
  end

  unless valid_mappings
    File.write(err_file, "#{last_error_class}: #{last_error}\n")
    warn "[FAIL] #{cid}: #{last_error_class}: #{last_error} (logged to #{err_file})"
    return
  end

  KotUtils.atomic_write(target_path) do |temp_file|
    File.open(temp_file, "w") do |f|
      valid_mappings.each { |m| f.puts(m.to_json) }
    end
  end

  FileUtils.rm_f(err_file)
  label = valid_mappings.empty? ? "infrastructure component, no processes" : "#{valid_mappings.size} processes"
  puts "[OK] #{target_path} (#{label})"
}

# PULL ARCHITECTURE: Define the target state
TARGET_COMP_PROCESSES_JSONLS = VALID_COMPONENT_IDS.map { |cid|
  "work/ta/#{cid}/#{cid}_processes.jsonl"
}

multitask :_all_comp_processes => TARGET_COMP_PROCESSES_JSONLS

desc "Map components to processes (all: rake map_processes, single: rake 'map_processes[К-КМ-А]')"
task :map_processes, [:component_id] do |_, args|
  if args[:component_id]
    cid = args[:component_id]
    Rake::Task["work/ta/#{cid}/#{cid}_processes.jsonl"].invoke
  else
    Rake::Task[:_all_comp_processes].invoke
  end
end

# THE RULE: aggregates file + prompt + processes dict -> {cid}_processes.jsonl
rule(%r{^work/ta/([^/]+)/\1_processes\.jsonl$} => [
  proc { |t|
    cid = t.match(%r{work/ta/([^/]+)/})[1]
    "work/ta/#{cid}/#{cid}_aggregates.jsonl"
  },
  COMP_PROCESSES_PROMPT_FILE,
  PROCESSES_DICT
]) do |t|
  cid = t.name.match(%r{work/ta/([^/]+)/})[1]

  EXTRACT_COMP_PROCESSES.call(cid, t.prerequisites[0], t.prerequisites[1], t.name)
end
