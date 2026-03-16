require "ruby_llm"
require "json"
require "kot_utils" # Brings in your atomic_write

# Global Setup (Stateless)
RubyLLM.configure do |config|
  config.openai_use_system_role = true
  config.openai_api_base = ENV.fetch("OPENAI_API_BASE")
  config.openai_api_key = ENV.fetch("OPENAI_API_KEY")
end

LLM_MODEL = ENV["LLM_MODEL"] || "GLM-4.5-Air"
ROLES_PROMPT_FILE = "raw/prompts/extract_roles.txt"

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
  end

  roles
}

EXTRACT_ROLES = ->(opis_path, prompt_path, target_path) {
  id = target_path.match(%r{work/([^/]+)/})[1]

  # 1. Explicitly force UTF-8 on all our file reads
  user_prompt_template = File.read(prompt_path, encoding: "UTF-8")
  opis_content = File.read(opis_path, encoding: "UTF-8")

  # 2. Inject the dynamic ID into the template
  user_prompt = user_prompt_template.gsub(/\{id\}|\#\{id\}/, id)

  # 3. Append the file content directly to the prompt text
  user_prompt += "\n\n### ИСХОДНЫЙ ДОКУМЕНТ:\n#{opis_content}"

  system_prompt = %(
    You are an experienced business analyst with deep knowledge of Russian Arbitration Court processes and expertise in BPMN2 diagrams. You write in fluent and correct technical Russian only, except for technical terms.
  ).strip

  chat = RubyLLM.chat(
    model: LLM_MODEL,
    provider: :openai,
    assume_model_exists: true
  ).with_params(response_format: {type: "json_object"})
    .with_instructions(system_prompt)
    .with_temperature(0.3)

  max_retries = 3
  attempts = 0
  valid_roles = nil
  last_error = nil

  while attempts < max_retries && !valid_roles
    attempts += 1
    begin
      # 4. Drop the `with: opis_path` parameter entirely.
      # The file content is now safely baked into the UTF-8 user_prompt string.
      msg = if attempts == 1
        chat.ask(user_prompt)
      else
        warn "[WARN] #{id}: Retry #{attempts}/#{max_retries} due to: #{last_error}"
        chat.ask("Your previous response failed schema validation: #{last_error}. Please correct your output and return ONLY the valid JSON array.")
      end

      # Keep the boundary sanitization on the way back down
      parsed_json = JSON.parse(msg.content.dup.force_encoding("UTF-8"))
      valid_roles = VALIDATE_ROLES.call(parsed_json)
    rescue JSON::ParserError, RuntimeError => e
      last_error = e.message
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
TARGET_ROLES_JSONLS = PROCESS_IDS.map { |id| "work/#{id}/#{id}_roles.jsonl" }

desc "Extract participant roles using LLM"
multitask roles: TARGET_ROLES_JSONLS

# 4. THE RULE: Maps target -> [opis.md, prompt.txt]
rule(%r{^work/([^/]+)/\1_roles\.jsonl$} => [
  proc do |t|
    id = t.match(%r{work/([^/]+)/})[1]
    "work/#{id}/#{id}_opis.md"
  end,
  ROLES_PROMPT_FILE # <- Magic. If you edit the prompt, Rake regenerates all roles.
]) do |t|
  opis_file = t.prerequisites[0]
  prompt_file = t.prerequisites[1]

  EXTRACT_ROLES.call(opis_file, prompt_file, t.name)
end
