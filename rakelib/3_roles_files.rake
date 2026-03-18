require "ruby_llm"
require "json"
require "kot_utils" # Brings in your atomic_write

QUIET = %w[1 true yes].include?(ENV["QUIET"]&.downcase) unless defined?(QUIET)

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

ROLES_MODEL = ENV["ROLES_MODEL"] || "claude-sonnet-4-5"
ROLES_PROMPT_FILE = "raw/prompts/extract_roles.txt"
PARTICIPANTS_FILE = "raw/data/grouped_participants.json"

VALID_PARTICIPANT_CODES = JSON.parse(File.read(PARTICIPANTS_FILE, encoding: "UTF-8"))
  .flat_map { |group| group["members"].map { |m| m["code"] } }

# Strictly enforces the schema. If it fails, it raises an error
# that we will feed directly back to the LLM.
VALIDATE_ROLES = ->(parsed_json) {
  roles = parsed_json.is_a?(Array) ? parsed_json : parsed_json["roles"]
  raise "Expected a JSON array or an object with a 'roles' array" unless roles.is_a?(Array)

  roles.each_with_index do |role, i|
    %w[role_id role description].each do |key|
      raise "Missing '#{key}' in role at index #{i}" unless role.key?(key)

      val = role[key].to_s

      # 1. THE TARGETED BAN: Catch Chinese characters explicitly
      if val.match?(/\p{Han}/)
        raise "Hallucinated Chinese characters detected in #{key}: '#{val}'. Use Russian only."
      end

      # 2. THE STRICT BAN (Optional): Catch ANY letter that is NOT Cyrillic or Latin
      # (This allows Russian and English technical terms, but bans Chinese, Arabic, Hiragana, etc.)
      # \p{L} is "any letter". (?!\p{Cyrillic}|\p{Latin}) means "not Cyrillic or Latin".
      if val.match?(/(?!\p{Cyrillic}|\p{Latin})\p{L}/)
        raise "Invalid foreign characters detected in #{key}: '#{val}'. Use Russian only."
      end

      # 3. THE DRACONIAN BAN (Optional): Catch ANY letter that is NOT Cyrillic
      # If you want to absolutely forbid English words too, use this instead of #2.
      # if val.match?(/(?!\p{Cyrillic})\p{L}/)
      #   raise "Non-Russian letters (e.g. English) detected in #{key}: '#{val}'. Use Russian only."
      # end
    end

    # 4. Participant linkage validation
    participant = role["participant"]
    raise "Missing 'participant' in role at index #{i}" unless participant.is_a?(Hash)
    raise "Missing 'code' in participant at index #{i}" unless participant.key?("code")
    raise "Missing 'name' in participant at index #{i}" unless participant.key?("name")
    unless VALID_PARTICIPANT_CODES.include?(participant["code"])
      raise "Invalid participant code '#{participant["code"]}' at index #{i}. Valid codes: #{VALID_PARTICIPANT_CODES.join(", ")}"
    end
  end

  roles
}

EXTRACT_ROLES = ->(opis_path, prompt_path, participants_path, target_path) {
  id = target_path.match(%r{work/ba/([^/]+)/})[1]

  # 1. Explicitly force UTF-8 on all our file reads
  user_prompt_template = File.read(prompt_path, encoding: "UTF-8")
  opis_content = File.read(opis_path, encoding: "UTF-8")
  participants_content = File.read(participants_path, encoding: "UTF-8")

  # 2. Inject the dynamic ID into the template
  user_prompt = user_prompt_template % {process_id: id}

  # 3. Append the file content and participants dictionary to the prompt text
  user_prompt += "\n\n### СПРАВОЧНИК УЧАСТНИКОВ ПРОЦЕССА:\n#{participants_content}"
  user_prompt += "\n\n### ИСХОДНЫЙ ДОКУМЕНТ:\n#{opis_content}"

  system_prompt = %(
    You are an experienced business analyst with deep knowledge of Russian Arbitration Court processes and expertise in BPMN2 diagrams. You write in fluent and correct technical Russian only, except for technical terms.
  ).strip

  temperature = 0.3
  max_retries = 3

  unless QUIET
    warn "[#{id}] model=#{ROLES_MODEL} temp=#{temperature} prompt=#{user_prompt.size} chars"
  end

  chat = RubyLLM.chat(
    model: ROLES_MODEL,
    provider: :anthropic,
    assume_model_exists: true
  ).with_instructions(system_prompt)
    .with_temperature(temperature)
  attempts = 0
  valid_roles = nil
  last_error = nil

  while attempts < max_retries && !valid_roles
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
      valid_roles = VALIDATE_ROLES.call(parsed_json)
    rescue JSON::ParserError, RuntimeError => e
      last_error = e.message
      warn "[#{id}] Validation failed: #{last_error}" unless QUIET
    end
  end

  raise "[FAIL] #{id}: Could not generate valid roles after #{max_retries} attempts. Last error: #{last_error}" unless valid_roles

  KotUtils.atomic_write(target_path) do |temp_file|
    File.open(temp_file, "w") do |f|
      valid_roles.each { |role| f.puts(role.to_json) }
    end
  end

  puts "[OK] #{target_path} (Extracted #{valid_roles.size} roles)"
}

# PULL ARCHITECTURE: Define the target state
TARGET_ROLES_JSONLS = PROCESS_IDS.map { |id| "work/ba/#{id}/#{id}_roles.jsonl" }

desc "Extract participant roles using LLM"
multitask roles: TARGET_ROLES_JSONLS

# 4. THE RULE: Maps target -> [opis.md, prompt.txt]
rule(%r{^work/ba/([^/]+)/\1_roles\.jsonl$} => [
  proc do |t|
    id = t.match(%r{work/ba/([^/]+)/})[1]
    "work/ba/#{id}/#{id}_opis.md"
  end,
  ROLES_PROMPT_FILE,
  PARTICIPANTS_FILE
]) do |t|
  opis_file = t.prerequisites[0]
  prompt_file = t.prerequisites[1]
  participants_file = t.prerequisites[2]

  EXTRACT_ROLES.call(opis_file, prompt_file, participants_file, t.name)
end
