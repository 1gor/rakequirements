QUIET = %w[1 true yes].include?(ENV["QUIET"]&.downcase) unless defined?(QUIET)
COMPONENTS_FILE = "raw/data/components.jsonl"
COMPONENTS_PROMPT_FILE = "raw/prompts/map_components.txt"
COMPONENTS_MODEL = ENV["COMPONENTS_MODEL"] || "claude-sonnet-4-5"

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

# Strip markdown code fences that LLMs wrap around JSON when not using response_format
def strip_json_fences(text)
  text = text.strip
  text = text.sub(/\A```(?:json)?\s*\n?/, "").sub(/\n?\s*```\z/, "") if text.start_with?("```")
  text
end

VALID_COMPONENT_IDS = File.foreach(COMPONENTS_FILE)
  .map { |line| JSON.parse(line)["ID"] }
  .to_a
  .freeze

VALIDATE_COMPONENTS = ->(parsed_json) {
  mappings = parsed_json.is_a?(Array) ? parsed_json : parsed_json["components"]
  raise "Expected a JSON array of component mappings" unless mappings.is_a?(Array)
  raise "Empty component list — every process should touch at least 3 components" if mappings.size < 3

  mappings.each_with_index do |mapping, i|
    %w[component_id relevance].each do |key|
      raise "Missing '#{key}' at index #{i}" unless mapping.key?(key)
    end

    cid = mapping["component_id"]
    unless VALID_COMPONENT_IDS.include?(cid)
      raise "Unknown component_id '#{cid}' at index #{i}. Must be one of: #{VALID_COMPONENT_IDS.first(10).join(", ")}..."
    end

    relevance = mapping["relevance"].to_s

    if relevance.match?(/\p{Han}/)
      raise "Chinese characters in relevance at index #{i}: '#{relevance}'"
    end

    if relevance.match?(/(?!\p{Cyrillic}|\p{Latin})\p{L}/)
      raise "Invalid foreign characters in relevance at index #{i}: '#{relevance}'"
    end

    raise "Relevance too short at index #{i} — provide a meaningful justification" if relevance.size < 10
  end

  dups = mappings.map { |m| m["component_id"] }.tally.select { |_, v| v > 1 }
  raise "Duplicate component_ids: #{dups.keys.join(", ")}" unless dups.empty?

  mappings
}

MAP_COMPONENTS = ->(opis_path, processes_path, prompt_path, components_path, target_path) {
  id = target_path.match(%r{work/ba/([^/]+)/})[1]

  user_prompt_template = File.read(prompt_path, encoding: "UTF-8")
  opis_content = File.read(opis_path, encoding: "UTF-8")
  processes_content = File.read(processes_path, encoding: "UTF-8")
  components_content = File.read(components_path, encoding: "UTF-8")

  user_prompt = user_prompt_template % {process_id: id}
  user_prompt += "\n\n### КАТАЛОГ КОМПОНЕНТОВ СИСТЕМЫ:\n#{components_content}"
  user_prompt += "\n\n### СВЯЗАННЫЕ ПРОЦЕССЫ:\n#{processes_content}"
  user_prompt += "\n\n### ИСХОДНЫЙ ДОКУМЕНТ:\n#{opis_content}"

  system_prompt = %(
    You are an experienced business analyst and system architect with deep knowledge of Russian Arbitration Court processes. You write in fluent and correct technical Russian only, except for technical terms.
  ).strip

  temperature = 0.2
  max_retries = 3

  unless QUIET
    warn "[#{id}] model=#{COMPONENTS_MODEL} temp=#{temperature} prompt=#{user_prompt.size} chars"
  end

  chat = RubyLLM.chat(
    model: COMPONENTS_MODEL,
    provider: :anthropic,
    assume_model_exists: true
  ).with_instructions(system_prompt)
    .with_temperature(temperature)

  attempts = 0
  valid_mappings = nil
  last_error = nil

  while attempts < max_retries && !valid_mappings
    attempts += 1
    begin
      t0 = Time.now
      msg = if attempts == 1
        warn "[#{id}] Submitting to LLM (attempt 1/#{max_retries})..." unless QUIET
        chat.ask(user_prompt)
      else
        warn "[#{id}] Retry #{attempts}/#{max_retries} — #{last_error}" unless QUIET
        chat.ask("Your previous response failed schema validation: #{last_error}. Please correct your output and return ONLY the valid JSON array.")
      end
      elapsed = (Time.now - t0).round(1)

      raw = msg.content.dup.force_encoding("UTF-8")
      warn "[#{id}] Response received (#{elapsed}s, #{raw.size} chars). Validating..." unless QUIET
      parsed_json = JSON.parse(strip_json_fences(raw))
      valid_mappings = VALIDATE_COMPONENTS.call(parsed_json)
    rescue JSON::ParserError, RuntimeError => e
      last_error = e.message
      last_error_class = e.class.name
      warn "[#{id}] Validation failed: #{last_error}" unless QUIET
    rescue RubyLLM::Error => e
      last_error = e.message
      last_error_class = e.class.name
      warn "[#{id}] LLM error (#{last_error_class}): #{last_error}" unless QUIET
    end
  end

  err_file = "#{target_path}.err"

  unless valid_mappings
    File.write(err_file, "#{last_error_class}: #{last_error}\n")
    warn "[FAIL] #{id}: #{last_error_class}: #{last_error} (logged to #{err_file})"
    return
  end

  KotUtils.atomic_write(target_path) do |temp_file|
    File.open(temp_file, "w") do |f|
      valid_mappings.each { |mapping| f.puts(mapping.to_json) }
    end
  end

  FileUtils.rm_f(err_file)
  puts "[OK] #{target_path} (#{valid_mappings.size} components mapped)"
}

# PULL ARCHITECTURE: Define the target state
TARGET_COMPONENT_JSONLS = PROCESS_IDS.map { |id| "work/ba/#{id}/#{id}_components.jsonl" }

desc "Map system components to each business process"
multitask components: TARGET_COMPONENT_JSONLS

# THE RULE: Maps target -> [opis.md, processes.jsonl, prompt.txt, components.jsonl]
rule(%r{^work/ba/([^/]+)/\1_components\.jsonl$} => [
  proc do |t|
    id = t.match(%r{work/ba/([^/]+)/})[1]
    "work/ba/#{id}/#{id}_opis.md"
  end,
  proc do |t|
    id = t.match(%r{work/ba/([^/]+)/})[1]
    "work/ba/#{id}/#{id}_processes.jsonl"
  end,
  COMPONENTS_PROMPT_FILE,
  COMPONENTS_FILE
]) do |t|
  opis_file = t.prerequisites[0]
  processes_file = t.prerequisites[1]
  prompt_file = t.prerequisites[2]
  components_file = t.prerequisites[3]

  MAP_COMPONENTS.call(opis_file, processes_file, prompt_file, components_file, t.name)
end
