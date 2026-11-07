require "ruby_llm"
require "json"
require "kot_utils" # Brings in your atomic_write
require "analyst_registry"

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

# Stage 3: roles from the analysts' actors (the «Я КАК» column, read by
# stage 3b), split into atomic roles as in the approved May KOT and linked to
# participants. Output keeps the May schema, so doc tables (2) and (3) are
# unchanged, plus "actors": the verbatim actor strings each role comes from.
# Stage 5 inverts that list to give every story its role_ids.

ROLES_MODEL = ENV["ROLES_MODEL"] || "claude-sonnet-4-5"
ROLES_PROMPT_FILE = "raw/prompts/extract_roles.txt"
PARTICIPANTS_FILE = "raw/data/grouped_participants.json"
ROLE_PRECEDENTS_FILE = "raw/data/may_role_participants.jsonl"

PARTICIPANT_NAMES = JSON.parse(File.read(PARTICIPANTS_FILE, encoding: "UTF-8"))
  .flat_map { |group| group["members"] }
  .to_h { |m| [m["code"], m["name"]] }
VALID_PARTICIPANT_CODES = PARTICIPANT_NAMES.keys

# Distinct actors in order of first appearance, as { "A1" => text }.
ACTOR_IDS = ->(stories) {
  stories.map { |s| s["actor"] }.uniq.each_with_index.to_h { |actor, i| ["A#{i + 1}", actor] }
}

# Checks the LLM answer and turns it into role records. Raises with a message
# that is fed back to the LLM on the next attempt.
VALIDATE_ROLES = ->(parsed_json, pid, actors) {
  roles = parsed_json.is_a?(Hash) ? parsed_json["roles"] : parsed_json
  raise "Expected a JSON object with a non-empty 'roles' array" unless roles.is_a?(Array) && !roles.empty?

  covered = Set.new
  names = Set.new
  records = roles.each_with_index.map do |role, i|
    raise "Role at index #{i} is not an object" unless role.is_a?(Hash)

    %w[role participant_code actors description].each do |key|
      raise "Missing '#{key}' in role at index #{i}" unless role.key?(key)
    end

    name = role["role"].to_s.strip
    description = role["description"].to_s.strip
    raise "Empty role name at index #{i}" if name.empty?
    raise "Empty description for role '#{name}'" if description.empty?

    {"role" => name, "description" => description}.each do |key, val|
      raise "Chinese characters in #{key} of role '#{name}'. Use Russian only." if val.match?(/\p{Han}/)
      if val.match?(/(?!\p{Cyrillic}|\p{Latin})\p{L}/)
        raise "Letters other than Cyrillic or Latin in #{key} of role '#{name}'. Use Russian only."
      end
    end

    raise "Role '#{name}' is an automated actor. Never create a role for «Система»." if name.match?(/\A(система|автоматическ)/i)
    raise "Duplicate role '#{name}'. Create each role once and list all of its actors." unless names.add?(name.downcase)

    code = role["participant_code"].to_s.strip
    unless PARTICIPANT_NAMES.key?(code)
      raise "Invalid participant code '#{code}' for role '#{name}'. Valid codes: #{VALID_PARTICIPANT_CODES.join(", ")}"
    end

    ids = Array(role["actors"]).map { |a| a.to_s.strip }.uniq
    raise "Role '#{name}' lists no actors" if ids.empty?

    unknown = ids - actors.keys
    raise "Role '#{name}' lists unknown actor ids #{unknown.join(", ")}. Valid ids: #{actors.keys.join(", ")}" unless unknown.empty?

    covered.merge(ids)
    {
      "role_id" => format("%s-R-%02d", pid, i + 1),
      "role" => name,
      "description" => description,
      "participant" => {"code" => code, "name" => PARTICIPANT_NAMES[code]},
      "actors" => ids.sort_by { |a| a.delete_prefix("A").to_i }.map { |a| actors[a] }
    }
  end

  missing = actors.keys - covered.to_a
  unless missing.empty?
    raise "Actors not covered by any role: #{missing.map { |a| "#{a} «#{actors[a]}»" }.join("; ")}. Every actor must appear in at least one role."
  end

  records
}

# The user prompt for one process and its actor ids. Separate from the LLM
# call so that a prompt can be rendered and read without calling the LLM.
ROLES_PROMPT = ->(id, stories_path, opis_path, prompt_path, participants_path, precedents_path) {
  stories = File.foreach(stories_path, encoding: "UTF-8").reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }
  actors = ACTOR_IDS.call(stories)
  actor_id = actors.invert
  opis = File.read(opis_path, encoding: "UTF-8")
  passport = AnalystRegistry.passport(opis)
  passport["Наименование процесса"] ||= AnalystRegistry.title(opis)
  precedents = File.foreach(precedents_path, encoding: "UTF-8").reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }

  user_prompt = File.read(prompt_path, encoding: "UTF-8") % {process_id: id}
  user_prompt += "\n\n### АКТОРЫ ПРОЦЕССА (id: текст из колонки «Я КАК»)\n"
  user_prompt += actors.map { |aid, text| "#{aid}: #{text}" }.join("\n")
  user_prompt += "\n\n### ПОЛЬЗОВАТЕЛЬСКИЕ ИСТОРИИ (story_id | актор | хочу | чтобы)\n"
  user_prompt += stories.map { |s| [s["story_id"], actor_id[s["actor"]], s["want"], s["in_order_to"]].join(" | ") }.join("\n")
  user_prompt += "\n\n### ПАСПОРТ ПРОЦЕССА\n"
  user_prompt += passport.map { |k, v| "#{k}: #{v}" }.join("\n")
  user_prompt += "\n\n### СПРАВОЧНИК УЧАСТНИКОВ ПРОЦЕССА\n#{File.read(participants_path, encoding: "UTF-8")}"
  user_prompt += "\n\n### РОЛИ ИЗ УТВЕРЖДЁННОГО КОТ (роль → код участника)\n"
  user_prompt += precedents.map { |r| "#{r["role"]} → #{r["participant_code"]}" }.join("\n")

  [user_prompt, actors]
}

EXTRACT_ROLES = ->(stories_path, opis_path, prompt_path, participants_path, precedents_path, target_path) {
  id = target_path.match(%r{work/ba/([^/]+)/})[1]
  user_prompt, actors = ROLES_PROMPT.call(id, stories_path, opis_path, prompt_path, participants_path, precedents_path)
  stories_count = File.foreach(stories_path).count { |l| !l.strip.empty? }

  system_prompt = %(
    You are an experienced business analyst with deep knowledge of Russian Arbitration Court processes and expertise in BPMN2 diagrams. You write in fluent and correct technical Russian only, except for technical terms.
  ).strip

  temperature = 0.3
  max_retries = 3

  unless QUIET
    warn "[#{id}] model=#{ROLES_MODEL} temp=#{temperature} actors=#{actors.size} stories=#{stories_count} prompt=#{user_prompt.size} chars"
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
  last_error_class = nil

  while attempts < max_retries && !valid_roles
    attempts += 1
    begin
      t0 = Time.now
      msg = if attempts == 1
        warn "[#{id}] Submitting to LLM (attempt 1/#{max_retries})..." unless QUIET
        chat.ask(user_prompt)
      else
        warn "[#{id}] Retry #{attempts}/#{max_retries} — #{last_error}" unless QUIET
        chat.ask("Your previous response failed validation: #{last_error} Please correct your output and return ONLY the valid JSON object.")
      end
      elapsed = (Time.now - t0).round(1)

      raw = msg.content.dup.force_encoding("UTF-8")
      warn "[#{id}] Response received (#{elapsed}s, #{raw.size} chars). Validating..." unless QUIET
      parsed_json = JSON.parse(strip_json_fences(raw))
      valid_roles = VALIDATE_ROLES.call(parsed_json, id, actors)
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

  unless valid_roles
    File.write(err_file, "#{last_error_class}: #{last_error}\n")
    warn "[FAIL] #{id}: #{last_error_class}: #{last_error} (logged to #{err_file})"
    return
  end

  KotUtils.atomic_write(target_path) do |temp_file|
    File.open(temp_file, "w") do |f|
      valid_roles.each { |role| f.puts(JSON.generate(role)) }
    end
  end

  FileUtils.rm_f(err_file)
  puts "[OK] #{target_path} (#{valid_roles.size} roles from #{actors.size} actors)"
}

# PULL ARCHITECTURE: Define the target state
TARGET_ROLES_JSONLS = PROCESS_IDS.map { |id| "work/ba/#{id}/#{id}_roles.jsonl" }

desc "Stage 3: roles from the analysts' actors, linked to participants (LLM)"
multitask roles: TARGET_ROLES_JSONLS

# THE RULE: roles <- stories read by stage 3b, opis.md (passport), prompt,
# participant dictionary, May precedents
rule(%r{^work/ba/([^/]+)/\1_roles\.jsonl$} => [
  proc do |t|
    id = t.match(%r{work/ba/([^/]+)/})[1]
    "work/ba/#{id}/#{id}_user_stories_src.jsonl"
  end,
  proc do |t|
    id = t.match(%r{work/ba/([^/]+)/})[1]
    "work/ba/#{id}/#{id}_opis.md"
  end,
  ROLES_PROMPT_FILE,
  PARTICIPANTS_FILE,
  ROLE_PRECEDENTS_FILE
]) do |t|
  EXTRACT_ROLES.call(*t.prerequisites.first(5), t.name)
end
