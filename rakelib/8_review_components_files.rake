require "ruby_llm"
require "json"
require "kot_utils"

QUIET = %w[1 true yes].include?(ENV["QUIET"]&.downcase) unless defined?(QUIET)

REVIEW_COMPONENTS_PROMPT_FILE = "raw/prompts/review_components.txt"
REVIEW_COMPONENTS_MODEL = ENV["REVIEW_COMPONENTS_MODEL"] || "claude-sonnet-4-5"

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

# Load full component catalog for validation
FULL_COMPONENT_IDS = File.foreach(COMPONENTS_FILE)
  .map { |line| JSON.parse(line)["ID"] }
  .to_a
  .freeze

VALIDATE_REVIEW = ->(parsed_json, id, valid_story_ids) {
  additions = parsed_json.is_a?(Array) ? parsed_json : parsed_json["additions"]
  raise "Expected a JSON array" unless additions.is_a?(Array)

  # Empty array is valid — all stories may be correctly linked
  return additions if additions.empty?

  additions.each_with_index do |a, i|
    %w[story_id add_component_id reason].each do |key|
      raise "Missing '#{key}' at index #{i}" unless a.key?(key)
    end

    sid = a["story_id"]
    unless valid_story_ids.include?(sid)
      raise "Unknown story_id '#{sid}' at index #{i}. Valid: #{valid_story_ids.first(5).join(", ")}..."
    end

    cid = a["add_component_id"]
    unless FULL_COMPONENT_IDS.include?(cid)
      raise "Unknown component_id '#{cid}' at index #{i}"
    end

    reason = a["reason"].to_s
    raise "Chinese characters in reason at index #{i}" if reason.match?(/\p{Han}/)
    raise "Invalid foreign characters in reason at index #{i}" if reason.match?(/(?!\p{Cyrillic}|\p{Latin})\p{L}/)
    raise "Reason too short at index #{i}" if reason.size < 20
  end

  additions
}

REVIEW_COMPONENTS = ->(id, opis_path, stories_path, prompt_path, target_path) {
  err_file = "#{target_path}.err"

  opis_content = File.read(opis_path, encoding: "UTF-8")
  stories_content = File.read(stories_path, encoding: "UTF-8")
  components_content = File.read(COMPONENTS_FILE, encoding: "UTF-8")
  user_prompt_template = File.read(prompt_path, encoding: "UTF-8")

  # Parse stories for validation
  valid_story_ids = File.foreach(stories_path)
    .map { |line| JSON.parse(line)["story_id"] }
    .to_a

  user_prompt = user_prompt_template % {process_id: id}
  user_prompt += "\n\n### ПОЛНЫЙ КАТАЛОГ КОМПОНЕНТОВ (#{FULL_COMPONENT_IDS.size} шт.):\n#{components_content}"
  user_prompt += "\n\n### ПОЛЬЗОВАТЕЛЬСКИЕ ИСТОРИИ ПРОЦЕССА:\n#{stories_content}"
  user_prompt += "\n\n### ОПИСАНИЕ ПРОЦЕССА:\n#{opis_content}"

  system_prompt = %(
    You are a senior DDD architect and Russian Arbitration Court domain expert. You combine deep knowledge of aggregate boundaries, bounded contexts, and event-driven architecture with practical understanding of court proceedings. You write in fluent technical Russian.
  ).strip

  temperature = 0.2
  max_retries = 3

  unless QUIET
    warn "[#{id}] model=#{REVIEW_COMPONENTS_MODEL} temp=#{temperature} stories=#{valid_story_ids.size} prompt=#{user_prompt.size} chars"
  end

  chat = RubyLLM.chat(
    model: REVIEW_COMPONENTS_MODEL,
    provider: :anthropic,
    assume_model_exists: true
  ).with_instructions(system_prompt)
    .with_temperature(temperature)

  attempts = 0
  valid_additions = nil
  last_error = nil
  last_error_class = nil

  while attempts < max_retries && !valid_additions
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
      valid_additions = VALIDATE_REVIEW.call(parsed_json, id, valid_story_ids)
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

  unless valid_additions
    File.write(err_file, "#{last_error_class}: #{last_error}\n")
    warn "[FAIL] #{id}: #{last_error_class}: #{last_error} (logged to #{err_file})"
    return
  end

  KotUtils.atomic_write(target_path) do |temp_file|
    File.open(temp_file, "w") do |f|
      valid_additions.each { |a| f.puts(a.to_json) }
    end
  end

  FileUtils.rm_f(err_file)
  label = valid_additions.empty? ? "no gaps found" : "#{valid_additions.size} missing links"
  puts "[OK] #{target_path} (#{label})"
}

# Apply review results: merge additions into _components.jsonl and _user_stories.jsonl
APPLY_REVIEW = ->(id) {
  review_file = "work/ba/#{id}/#{id}_components_review.jsonl"
  return unless File.exist?(review_file)

  additions = File.foreach(review_file).map { |line| JSON.parse(line) }.to_a
  return if additions.empty?

  # 1. Add new component_ids to _components.jsonl
  components_file = "work/ba/#{id}/#{id}_components.jsonl"
  existing_cids = File.foreach(components_file)
    .map { |line| JSON.parse(line)["component_id"] }
    .to_a
    .to_set

  new_cids = additions.map { |a| a["add_component_id"] }.uniq - existing_cids.to_a

  if new_cids.any?
    File.open(components_file, "a") do |f|
      new_cids.each do |cid|
        reasons = additions.select { |a| a["add_component_id"] == cid }.map { |a| a["reason"] }
        f.puts({component_id: cid, relevance: reasons.first}.to_json)
      end
    end
    puts "[MERGE] #{components_file}: added #{new_cids.size} components (#{new_cids.join(", ")})"
  end

  # 2. Add component_ids to _user_stories.jsonl
  stories_file = "work/ba/#{id}/#{id}_user_stories.jsonl"
  stories = File.foreach(stories_file).map { |line| JSON.parse(line) }.to_a
  modified = 0

  additions.each do |a|
    story = stories.find { |s| s["story_id"] == a["story_id"] }
    next unless story
    unless story["component_ids"].include?(a["add_component_id"])
      story["component_ids"] << a["add_component_id"]
      modified += 1
    end
  end

  if modified > 0
    KotUtils.atomic_write(stories_file) do |temp_file|
      File.open(temp_file, "w") do |f|
        stories.each { |s| f.puts(s.to_json) }
      end
    end
    puts "[MERGE] #{stories_file}: updated #{modified} story-component links"
  end
}

# PULL ARCHITECTURE: Define the target state
TARGET_REVIEW_JSONLS = PROCESS_IDS.map { |id| "work/ba/#{id}/#{id}_components_review.jsonl" }

multitask :_all_review_components => TARGET_REVIEW_JSONLS

desc "Review component links in user stories (all: rake review_components, single: rake 'review_components[KBP1]')"
task :review_components, [:process_id] do |_, args|
  if args[:process_id]
    id = args[:process_id]
    Rake::Task["work/ba/#{id}/#{id}_components_review.jsonl"].invoke
  else
    Rake::Task[:_all_review_components].invoke
  end
end

desc "Apply review results: merge missing links into components and stories"
task :apply_review, [:process_id] do |_, args|
  targets = args[:process_id] ? [args[:process_id]] : PROCESS_IDS

  applied = 0
  targets.each do |id|
    review_file = "work/ba/#{id}/#{id}_components_review.jsonl"
    next unless File.exist?(review_file)
    count = File.foreach(review_file).count
    next if count == 0
    APPLY_REVIEW.call(id)
    applied += 1
  end
  puts "[DONE] Applied reviews for #{applied} processes"
end

# THE RULE: opis.md + stories.jsonl + prompt -> review.jsonl
rule(%r{^work/ba/([^/]+)/\1_components_review\.jsonl$} => [
  proc { |t|
    id = t.match(%r{work/ba/([^/]+)/})[1]
    "work/ba/#{id}/#{id}_opis.md"
  },
  proc { |t|
    id = t.match(%r{work/ba/([^/]+)/})[1]
    "work/ba/#{id}/#{id}_user_stories.jsonl"
  },
  REVIEW_COMPONENTS_PROMPT_FILE,
  COMPONENTS_FILE
]) do |t|
  id = t.name.match(%r{work/ba/([^/]+)/})[1]

  REVIEW_COMPONENTS.call(id, t.prerequisites[0], t.prerequisites[1], t.prerequisites[2], t.name)
end
