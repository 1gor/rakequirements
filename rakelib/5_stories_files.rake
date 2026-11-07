require "analyst_registry"

STORIES_PROMPT_FILE = "raw/prompts/extract_user_stories.txt"
STORIES_MODEL = ENV["STORIES_MODEL"] || "claude-opus-4.6"
# Output token limit. Unset: May's 16384.
STORIES_MAX_TOKENS = ENV["STORIES_MAX_TOKENS"]&.to_i&.then { |n| n.positive? ? n : nil } || 16_384

# Build a lookup of full component definitions keyed by ID
COMPONENTS_CATALOG = File.foreach(COMPONENTS_FILE)
  .each_with_object({}) { |line, h|
    comp = JSON.parse(line)
    h[comp["ID"]] = comp
  }
  .freeze

# Stage 5: component links for the analysts' stories. The stories come from
# stage 3b and stay verbatim; the LLM returns only story_id → component_ids.
# Code adds the text, the verbatim actor as "role" (shown in «Я как») and
# "role_ids": the stage 3 roles whose "actors" list contains the story's actor.
# Output keeps the May schema with role_ids in place of role_id.

# { story_id => [role_id, ...] }
STORY_ROLE_IDS = ->(stories, roles) {
  by_actor = Hash.new { |h, k| h[k] = [] }
  roles.each { |r| (r["actors"] || []).each { |a| by_actor[a] << r["role_id"] } }
  stories.to_h { |s| [s["story_id"], by_actor[s["actor"]]] }
}

# The user prompt for one process. Separate from the LLM call so that a
# prompt can be rendered and read without calling the LLM.
STORIES_PROMPT = ->(id, stories, use_cases, opis, candidate_ids, prompt_path) {
  passport = AnalystRegistry.passport(opis)
  passport["Наименование процесса"] ||= AnalystRegistry.title(opis)

  user_prompt = File.read(prompt_path, encoding: "UTF-8") % {process_id: id}
  user_prompt += "\n\n### ПАСПОРТ ПРОЦЕССА\n"
  user_prompt += passport.map { |k, v| "#{k}: #{v}" }.join("\n")
  user_prompt += "\n\n### ПОЛЬЗОВАТЕЛЬСКИЕ ИСТОРИИ (story_id | я как | хочу | чтобы)\n"
  user_prompt += stories.map { |s| [s["story_id"], s["actor"], s["want"], s["in_order_to"]].join(" | ") }.join("\n")
  user_prompt += "\n\n### СЦЕНАРИИ ИСПОЛЬЗОВАНИЯ (UC)\n"
  user_prompt += if use_cases.empty?
    "нет"
  else
    use_cases.map { |u|
      (["#{u["uc_id"]} — #{u["title"]}"] + u["fields"].map { |k, v| "  #{k}: #{v}" }).join("\n")
    }.join("\n\n")
  end
  user_prompt += "\n\n### РЕЛЕВАНТНЫЕ КОМПОНЕНТЫ СИСТЕМЫ:\n"
  user_prompt + candidate_ids.filter_map { |cid| COMPONENTS_CATALOG[cid]&.to_json }.join("\n")
}

# Checks the LLM answer; returns { story_id => [component_id, ...] }. Raises
# with a message that is fed back to the LLM on the next attempt.
VALIDATE_LINKS = ->(parsed_json, story_ids, candidate_ids) {
  links = parsed_json.is_a?(Hash) ? (parsed_json["stories"] || parsed_json["links"]) : parsed_json
  raise "Expected a JSON array with one object per story" unless links.is_a?(Array)

  seen = {}
  links.each_with_index do |link, i|
    raise "Item at index #{i} is not an object" unless link.is_a?(Hash)

    sid = link["story_id"].to_s.strip
    raise "Unknown story_id '#{sid}' at index #{i}. Valid: #{story_ids.join(", ")}" unless story_ids.include?(sid)
    raise "Duplicate story_id '#{sid}' at index #{i}. Each story must appear exactly once." if seen.key?(sid)

    cids = link["component_ids"]
    raise "component_ids of '#{sid}' must be a non-empty array" unless cids.is_a?(Array) && !cids.empty?

    cids = cids.map { |c| c.to_s.strip }.uniq
    unknown = cids - candidate_ids
    unless unknown.empty?
      raise "Unknown component_id #{unknown.join(", ")} in story '#{sid}'. Valid for this process: #{candidate_ids.join(", ")}"
    end
    seen[sid] = cids
  end

  missing = story_ids - seen.keys
  raise "Stories without components: #{missing.join(", ")}. Every story must appear exactly once." unless missing.empty?

  seen
}

# Output records in the analysts' order.
ASSEMBLE_STORIES = ->(stories, role_ids, links) {
  stories.map do |s|
    {
      "story_id" => s["story_id"],
      "role_ids" => role_ids.fetch(s["story_id"]),
      "role" => s["actor"],
      "want" => s["want"],
      "in_order_to" => s["in_order_to"],
      "component_ids" => links.fetch(s["story_id"])
    }
  end
}

LINK_STORIES = ->(src_path, roles_path, components_map_path, use_cases_path, opis_path, prompt_path, target_path) {
  id = target_path.match(%r{work/ba/([^/]+)/})[1]
  err_file = "#{target_path}.err"

  stories = KotUtils.read_jsonl(src_path)
  roles = KotUtils.read_jsonl(roles_path)
  use_cases = KotUtils.read_jsonl(use_cases_path)
  candidate_ids = KotUtils.read_jsonl(components_map_path).map { |r| r["component_id"] }
  role_ids = STORY_ROLE_IDS.call(stories, roles)

  # Roles built from other actors than the current stories: rebuild roles first.
  orphans = stories.select { |s| role_ids[s["story_id"]].empty? }
  unless orphans.empty?
    message = "actors without a role in #{roles_path}: " +
      orphans.map { |s| "#{s["story_id"]} «#{s["actor"]}»" }.uniq.join("; ")
    File.write(err_file, "StaleRoles: #{message}\n")
    warn "[FAIL] #{id}: #{message} (logged to #{err_file})"
    next
  end

  user_prompt = STORIES_PROMPT.call(id, stories, use_cases, File.read(opis_path, encoding: "UTF-8"), candidate_ids, prompt_path)
  story_ids = stories.map { |s| s["story_id"] }

  system_prompt = %(
    You are an experienced business analyst with deep knowledge of Russian Arbitration Court processes and expertise in BPMN2 diagrams. You write in fluent and correct technical Russian only, except for technical terms.
  ).strip

  temperature = 0.3
  max_retries = 3

  unless QUIET
    warn "[#{id}] model=#{STORIES_MODEL} temp=#{temperature} stories=#{stories.size} use_cases=#{use_cases.size} components=#{candidate_ids.size} prompt=#{user_prompt.size} chars"
  end

  new_chat = -> {
    RubyLLM.chat(
      model: STORIES_MODEL,
      provider: :anthropic,
      assume_model_exists: true
    ).with_instructions(system_prompt)
      .with_temperature(temperature)
      .with_params(max_tokens: STORIES_MAX_TOKENS)
  }
  chat = new_chat.call
  send_prompt = true
  attempts = 0
  links = nil
  last_error = nil
  last_error_class = nil

  while attempts < max_retries && !links
    attempts += 1
    begin
      t0 = Time.now
      msg = if send_prompt
        warn "[#{id}] Submitting to LLM (attempt #{attempts}/#{max_retries})..." unless QUIET
        chat.ask(user_prompt)
      else
        warn "[#{id}] Retry #{attempts}/#{max_retries} — #{last_error}" unless QUIET
        chat.ask("Your previous response failed validation: #{last_error} Please correct your output and return ONLY the valid JSON array.")
      end
      elapsed = (Time.now - t0).round(1)

      raw = msg.content.to_s.dup.force_encoding("UTF-8")
      warn "[#{id}] Response received (#{elapsed}s, #{raw.size} chars). Validating..." unless QUIET
      if raw.strip.empty?
        # Nothing to correct: start a fresh conversation and send the prompt again.
        last_error = KotUtils.describe_empty_reply(msg, target_path, attempts)
        last_error_class = "EmptyReply"
        warn "[#{id}] #{last_error}" unless QUIET
        chat = new_chat.call
        send_prompt = true
        next
      end
      send_prompt = false

      links = VALIDATE_LINKS.call(JSON.parse(strip_json_fences(raw)), story_ids, candidate_ids)
    rescue JSON::ParserError, RuntimeError => e
      last_error = e.message
      last_error_class = e.class.name
      warn "[#{id}] Validation failed: #{last_error}" unless QUIET
    rescue RubyLLM::Error, Faraday::Error => e
      last_error = e.message
      last_error_class = e.class.name
      warn "[#{id}] LLM error (#{last_error_class}): #{last_error}" unless QUIET
      waited = KotUtils.recover_from_llm_error(chat, e, attempts, max_retries)
      warn "[#{id}] Waited #{waited}s after the rate limit" if waited.positive? && !QUIET
    end
  end

  unless links
    File.write(err_file, "#{last_error_class}: #{last_error}\n")
    warn "[FAIL] #{id}: #{last_error_class}: #{last_error} (logged to #{err_file})"
    next
  end

  records = ASSEMBLE_STORIES.call(stories, role_ids, links)
  KotUtils.atomic_write(target_path) do |temp_file|
    File.open(temp_file, "w") { |f| records.each { |r| f.puts(JSON.generate(r)) } }
  end

  FileUtils.rm_f(err_file)
  KotUtils.clear_thinking(target_path)
  # May wrote similarity warnings here; stories are no longer generated.
  FileUtils.rm_f(target_path.sub(/\.jsonl$/, ".warn"))
  puts "[OK] #{target_path} (#{records.size} user stories, #{links.values.sum(&:size)} component links)"
}

# PULL ARCHITECTURE: Define the target state
TARGET_STORY_JSONLS = PROCESS_IDS.map { |id| "work/ba/#{id}/#{id}_user_stories.jsonl" }

desc "Stage 5: link components to the analysts' user stories (LLM)"
multitask stories: TARGET_STORY_JSONLS

# THE RULE: stories (stage 3b), roles (stage 3), components (stage 4),
# use cases (stage 3b), opis.md (passport), prompt
rule(%r{^work/ba/([^/]+)/\1_user_stories\.jsonl$} => [
  proc do |t|
    id = t.match(%r{work/ba/([^/]+)/})[1]
    "work/ba/#{id}/#{id}_user_stories_src.jsonl"
  end,
  proc do |t|
    id = t.match(%r{work/ba/([^/]+)/})[1]
    "work/ba/#{id}/#{id}_roles.jsonl"
  end,
  proc do |t|
    id = t.match(%r{work/ba/([^/]+)/})[1]
    "work/ba/#{id}/#{id}_components.jsonl"
  end,
  proc do |t|
    id = t.match(%r{work/ba/([^/]+)/})[1]
    "work/ba/#{id}/#{id}_use_cases.jsonl"
  end,
  proc do |t|
    id = t.match(%r{work/ba/([^/]+)/})[1]
    "work/ba/#{id}/#{id}_opis.md"
  end,
  STORIES_PROMPT_FILE
]) do |t|
  LINK_STORIES.call(*t.prerequisites.first(6), t.name)
end
