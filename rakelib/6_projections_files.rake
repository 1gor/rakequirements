require "ruby_llm"
require "json"
require "set"
require "kot_utils"

QUIET = %w[1 true yes].include?(ENV["QUIET"]&.downcase) unless defined?(QUIET)

PROJECTIONS_PROMPT_FILE = "raw/prompts/extract_projections.txt"
PROJECTIONS_MODEL = ENV["PROJECTIONS_MODEL"] || "claude-sonnet-4-5"

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

VALIDATE_PROJECTIONS = ->(parsed_json, component_id) {
  projections = parsed_json.is_a?(Array) ? parsed_json : parsed_json["projections"]
  raise "Expected a JSON array of projections" unless projections.is_a?(Array)
  raise "No projections generated — every component should have at least one" if projections.empty?

  id_pattern = /\A#{Regexp.escape(component_id)}-PR-\d{2,3}\z/
  seen_ids = []

  projections.each_with_index do |proj, i|
    %w[projection_id name description].each do |key|
      raise "Missing '#{key}' at index #{i}" unless proj.key?(key)
    end

    pid = proj["projection_id"]
    unless pid.match?(id_pattern)
      raise "Invalid projection_id format '#{pid}' at index #{i}. Expected #{component_id}-PR-XX"
    end
    raise "Duplicate projection_id '#{pid}' at index #{i}" if seen_ids.include?(pid)
    seen_ids << pid

    %w[name description].each do |field|
      val = proj[field].to_s
      raise "Chinese characters in '#{field}' at index #{i}" if val.match?(/\p{Han}/)
      raise "Invalid foreign characters in '#{field}' at index #{i}" if val.match?(/(?!\p{Cyrillic}|\p{Latin})\p{L}/)
      raise "'#{field}' too short at index #{i}" if val.size < (field == "name" ? 5 : 20)
    end
  end

  projections
}

EXTRACT_PROJECTIONS = ->(cid, aggregates_path, prompt_path, target_path) {
  err_file = "#{target_path}.err"

  # Load component catalog entry
  component_entry = File.foreach(COMPONENTS_FILE)
    .map { |line| JSON.parse(line) }
    .find { |c| c["ID"] == cid }

  unless component_entry
    warn "[SKIP] #{cid}: Not found in components catalog"
    return
  end

  # Load stories referencing this component (across all processes)
  relevant_stories = FileList["work/ba/**/*_user_stories.jsonl"].flat_map { |f|
    next [] unless File.exist?(f)
    File.foreach(f).filter_map { |line|
      story = JSON.parse(line)
      story.slice("story_id", "role", "want", "in_order_to") if story["component_ids"].include?(cid)
    }
  }

  user_prompt_template = File.read(prompt_path, encoding: "UTF-8")
  aggregates_content = File.read(aggregates_path, encoding: "UTF-8")

  user_prompt = user_prompt_template % {component_id: cid}
  user_prompt += "\n\n### ОПИСАНИЕ КОМПОНЕНТА:\n#{component_entry.to_json}"
  user_prompt += "\n\n### ДОМЕННАЯ МОДЕЛЬ (АГРЕГАТЫ):\n#{aggregates_content}"

  context_label = nil

  if relevant_stories.any?
    user_prompt += "\n\n### ПОЛЬЗОВАТЕЛЬСКИЕ ИСТОРИИ (#{relevant_stories.size} шт.):\n"
    user_prompt += relevant_stories.map(&:to_json).join("\n")
    context_label = "stories=#{relevant_stories.size}"
  else
    # Fallback: use reverse-mapped process descriptions when no user stories exist
    reverse_map_file = "work/ta/#{cid}/#{cid}_processes.jsonl"
    unless File.exist?(reverse_map_file)
      warn "[SKIP] #{cid}: No user stories and no reverse process map — run 'rake map_processes[#{cid}]' first"
      return
    end
    mapped_processes = File.foreach(reverse_map_file).map { |line| JSON.parse(line) }
    if mapped_processes.empty?
      warn "[SKIP] #{cid}: No user stories and reverse map is empty (infrastructure component)"
      return
    end
    process_lookup = File.foreach(PROCESSES_DICT)
      .each_with_object({}) { |line, h| p = JSON.parse(line); h[p["process_id"]] = p }
    process_context = mapped_processes.filter_map { |m|
      process_lookup[m["process_id"]]
        &.slice("process_id", "name", "description")
        &.merge("relevance" => m["relevance"])
    }
    user_prompt += "\n\n### СВЯЗАННЫЕ ПРОЦЕССЫ (нет пользовательских историй; используются описания процессов):\n"
    user_prompt += process_context.map(&:to_json).join("\n")
    context_label = "fallback_processes=#{process_context.size}"
  end

  system_prompt = %(
    You are an experienced domain-driven design practitioner and system architect with deep knowledge of Russian Arbitration Court processes. You write in fluent and correct technical Russian only, except for technical terms.
  ).strip

  temperature = 0.2
  max_retries = 3

  unless QUIET
    warn "[#{cid}] model=#{PROJECTIONS_MODEL} temp=#{temperature} #{context_label} prompt=#{user_prompt.size} chars"
  end

  chat = RubyLLM.chat(
    model: PROJECTIONS_MODEL,
    provider: :anthropic,
    assume_model_exists: true
  ).with_instructions(system_prompt)
    .with_temperature(temperature)

  attempts = 0
  valid_projections = nil
  last_error = nil
  last_error_class = nil

  while attempts < max_retries && !valid_projections
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
      valid_projections = VALIDATE_PROJECTIONS.call(parsed_json, cid)
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

  unless valid_projections
    File.write(err_file, "#{last_error_class}: #{last_error}\n")
    warn "[FAIL] #{cid}: #{last_error_class}: #{last_error} (logged to #{err_file})"
    return
  end

  KotUtils.atomic_write(target_path) do |temp_file|
    File.open(temp_file, "w") do |f|
      valid_projections.each { |proj| f.puts(proj.to_json) }
    end
  end

  FileUtils.rm_f(err_file)
  puts "[OK] #{target_path} (#{valid_projections.size} projections)"
}

# PULL ARCHITECTURE: Define the target state
TARGET_PROJECTION_JSONLS = VALID_COMPONENT_IDS.map { |cid|
  "work/ta/#{cid}/#{cid}_projections.jsonl"
}

# All story files — listed as prerequisites so any story change triggers rebuild
ALL_STORY_JSONLS = FileList["work/ba/**/*_user_stories.jsonl"]

# Private multitask for parallel all-components build
multitask :_all_projections => TARGET_PROJECTION_JSONLS

desc "Generate projections (all: rake projections, single: rake 'projections[К-ПД]')"
task :projections, [:component_id] do |_, args|
  if args[:component_id]
    cid = args[:component_id]
    Rake::Task["work/ta/#{cid}/#{cid}_projections.jsonl"].invoke
  else
    Rake::Task[:_all_projections].invoke
  end
end

# THE RULE: aggregates file + prompt + all story files -> projections.jsonl
rule(%r{^work/ta/([^/]+)/\1_projections\.jsonl$} => [
  proc { |t|
    cid = t.match(%r{work/ta/([^/]+)/})[1]
    "work/ta/#{cid}/#{cid}_aggregates.jsonl"
  },
  PROJECTIONS_PROMPT_FILE,
  *ALL_STORY_JSONLS
]) do |t|
  cid = t.name.match(%r{work/ta/([^/]+)/})[1]
  aggregates_file = t.prerequisites[0]
  prompt_file = t.prerequisites[1]

  EXTRACT_PROJECTIONS.call(cid, aggregates_file, prompt_file, t.name)
end

desc "List components never referenced in any user story -> work/ta/orphaned-components.jsonl"
task :orphaned_components do
  referenced = FileList["work/ba/**/*_user_stories.jsonl"].each_with_object(Set.new) { |f, s|
    next unless File.exist?(f)
    File.foreach(f) { |line| JSON.parse(line)["component_ids"].each { |cid| s << cid } }
  }

  orphaned = VALID_COMPONENT_IDS.reject { |cid| referenced.include?(cid) }

  target = "work/ta/orphaned-components.jsonl"
  File.open(target, "w") do |f|
    orphaned.each do |cid|
      comp = COMPONENTS_CATALOG[cid]
      f.puts({
        component_id: cid,
        name: comp&.dig("Наименование компонента"),
        description: comp&.dig("Описание реализуемых функций")
      }.to_json)
    end
  end

  puts "[OK] #{target} (#{orphaned.size} orphaned out of #{VALID_COMPONENT_IDS.size} components)"
  orphaned.each { |cid| puts "  #{cid}" }
end
