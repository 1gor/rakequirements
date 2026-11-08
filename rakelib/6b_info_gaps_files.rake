require "ruby_llm"
require "json"
require "kot_utils"

QUIET = %w[1 true yes].include?(ENV["QUIET"]&.downcase) unless defined?(QUIET)

# Stage 6b: information object gaps, report only (epic nov-kot, decision 5).
# The information objects of the KOT are frozen from May: aggregates (table
# 10.1, codes {cid}-AG-NN), projections (table 10.2) and matrix 11. For each
# component the LLM reads its objects and the analysts' stories now linked to
# it, and lists the stories whose information need from this component no
# object represents. It writes only work/ta/{cid}/{cid}_info_gaps.jsonl;
# rake check:info_gaps collects them with the story text.

INFO_GAPS_PROMPT_FILE = "raw/prompts/info_gaps.txt"
INFO_GAPS_MODEL = ENV["INFO_GAPS_MODEL"] || PROJECTIONS_MODEL
# Output token limit (starting budget, doubled after a max_tokens reply).
# Unset: KotUtils::DEFAULT_OUTPUT_TOKENS.
INFO_GAPS_MAX_TOKENS = KotUtils.output_budget("INFO_GAPS_MAX_TOKENS")
# Stories per LLM call. A component linked to more stories is checked in
# batches of even size (К-МД, with 526 stories, in 4 calls).
INFO_GAPS_BATCH = [ENV.fetch("INFO_GAPS_BATCH", 150).to_i, 1].max
INFO_GAPS_STORY_FILES = PROCESS_IDS.map { |id| "work/ba/#{id}/#{id}_user_stories.jsonl" }

# The component's objects with the codes of the KOT registers: aggregates as
# {cid}-AG-NN (as table 10.1 numbers them), projections by projection_id.
INFO_OBJECTS = ->(cid) {
  aggregates = KotUtils.read_jsonl("work/ta/#{cid}/#{cid}_aggregates.jsonl").each_with_index.map { |a, i|
    {"object_id" => format("%s-AG-%02d", cid, i + 1), "kind" => "объект (агрегат)"}.merge(a.except("component_id"))
  }
  projections_file = "work/ta/#{cid}/#{cid}_projections.jsonl"
  projections = File.exist?(projections_file) ? KotUtils.read_jsonl(projections_file) : []
  aggregates + projections.map { |p|
    {"object_id" => p["projection_id"], "kind" => "справочник (проекция)", "name" => p["name"], "description" => p["description"]}
  }
}

# The stories of the active processes linked to the component.
INFO_GAPS_STORIES = ->(cid) {
  INFO_GAPS_STORY_FILES.flat_map { |f| KotUtils.read_jsonl(f) }.select { |s| s["component_ids"].include?(cid) }
}

# The user prompt for one batch of stories. Separate from the LLM call so that
# a prompt can be rendered and read without calling the LLM.
INFO_GAPS_PROMPT = ->(cid, objects, stories, prompt_path) {
  others = stories.flat_map { |s| s["component_ids"] }.uniq - [cid]
  user_prompt = File.read(prompt_path, encoding: "UTF-8") % {component_id: cid}
  user_prompt += "\n\n### ОПИСАНИЕ КОМПОНЕНТА:\n#{COMPONENTS_CATALOG.fetch(cid).to_json}"
  user_prompt += "\n\n### ИНФОРМАЦИОННЫЕ ОБЪЕКТЫ КОМПОНЕНТА:\n" + objects.map(&:to_json).join("\n")
  user_prompt += "\n\n### ДРУГИЕ КОМПОНЕНТЫ, СВЯЗАННЫЕ С ИСТОРИЯМИ:\n"
  user_prompt += others.empty? ? "нет" : others.filter_map { |c| COMPONENTS_CATALOG[c]&.to_json }.join("\n")
  user_prompt + "\n\n### ПОЛЬЗОВАТЕЛЬСКИЕ ИСТОРИИ (#{stories.size} шт.):\n" +
    stories.map { |s| s.slice("story_id", "role", "want", "in_order_to", "component_ids").to_json }.join("\n")
}

INFO_GAPS_TEXT_CHECK = ->(text, what, i, min) {
  raise "Chinese characters in #{what} at index #{i}" if text.match?(/\p{Han}/)
  raise "Invalid foreign characters in #{what} at index #{i}" if text.match?(/(?!\p{Cyrillic}|\p{Latin})\p{L}/)
  raise "#{what.capitalize} too short at index #{i}" if text.size < min
}

# Checks the LLM answer; returns the gap records. Raises with a message that
# is fed back to the LLM on the next attempt.
VALIDATE_INFO_GAPS = ->(parsed_json, story_ids, object_ids) {
  gaps = parsed_json.is_a?(Hash) ? parsed_json["gaps"] : parsed_json
  raise "Expected a JSON object with an array 'gaps'" unless gaps.is_a?(Array)

  gaps.each_with_index do |g, i|
    raise "gaps[#{i}] is not an object" unless g.is_a?(Hash)
    %w[story_id need closest_object_id reason].each do |key|
      raise "Missing '#{key}' in gaps at index #{i}" unless g.key?(key)
    end
    raise "Unknown story_id '#{g["story_id"]}' at index #{i}: report only stories of the list" unless story_ids.include?(g["story_id"])
    unless object_ids.include?(g["closest_object_id"])
      raise "Unknown closest_object_id '#{g["closest_object_id"]}' at index #{i}. Valid: #{object_ids.join(", ")}"
    end
    INFO_GAPS_TEXT_CHECK.call(g["need"].to_s, "need", i, 10)
    INFO_GAPS_TEXT_CHECK.call(g["reason"].to_s, "reason", i, 20)
  end

  gaps.map { |g| g.slice("story_id", "need", "closest_object_id", "reason") }
}

# One conversation for one batch: [gaps, nil, nil] or [nil, error class, error].
# thinking_key names the files of saved reasoning (tmp/thinking/).
INFO_GAPS_ASK = ->(label, user_prompt, story_ids, object_ids, thinking_key) {
  system_prompt = %(
    You are an experienced domain-driven design practitioner and system architect with deep knowledge of Russian Arbitration Court processes. You write in fluent and correct technical Russian only, except for technical terms.
  ).strip

  temperature = 0.2
  max_retries = 3

  unless QUIET
    warn "[#{label}] model=#{INFO_GAPS_MODEL} temp=#{temperature} stories=#{story_ids.size} objects=#{object_ids.size} prompt=#{user_prompt.size} chars"
  end

  # Output budget: doubled after a reply that ran out of it (see below).
  budget = INFO_GAPS_MAX_TOKENS
  new_chat = -> {
    c = RubyLLM.chat(
      model: INFO_GAPS_MODEL,
      provider: :anthropic,
      assume_model_exists: true,
      context: KotUtils.llm_context(budget)
    ).with_instructions(system_prompt)
      .with_temperature(temperature)
    budget ? c.with_params(max_tokens: budget) : c
  }
  chat = new_chat.call
  send_prompt = true

  attempts = 0
  rate_waits = 0
  correction = nil
  gaps = nil
  last_error = nil
  last_error_class = nil

  while attempts < max_retries && !gaps
    attempts += 1
    begin
      t0 = Time.now
      msg = if send_prompt
        warn "[#{label}] Submitting to LLM (attempt #{attempts}/#{max_retries})..." unless QUIET
        chat.ask(user_prompt)
      else
        warn "[#{label}] Retry #{attempts}/#{max_retries} — #{correction}" unless QUIET
        chat.ask("Your previous response failed schema validation: #{correction}. Please correct your output and return ONLY the valid JSON object.")
      end
      elapsed = (Time.now - t0).round(1)

      raw = msg.content.to_s.dup.force_encoding("UTF-8")
      warn "[#{label}] Response received (#{elapsed}s, #{raw.size} chars). Validating..." unless QUIET
      if raw.strip.empty? || KotUtils.out_of_budget?(msg)
        # Nothing to correct (no answer, or one cut off at max_tokens): start a
        # fresh conversation and send the prompt again, with a doubled budget
        # when this one ran out; the same budget would fail the same way.
        last_error = KotUtils.describe_empty_reply(msg, thinking_key, attempts)
        last_error_class = raw.strip.empty? ? "EmptyReply" : "TruncatedReply"
        warn "[#{label}] #{last_error}" unless QUIET
        if KotUtils.out_of_budget?(msg)
          budget = KotUtils.larger_budget(budget)
          warn "[#{label}] Next attempt with max_tokens=#{budget}" unless QUIET
        end
        chat = new_chat.call
        send_prompt = true
        next
      end
      send_prompt = false
      gaps = VALIDATE_INFO_GAPS.call(JSON.parse(strip_json_fences(raw)), story_ids, object_ids)
    rescue JSON::ParserError, RuntimeError => e
      last_error = e.message
      correction = last_error
      last_error_class = e.class.name
      warn "[#{label}] Validation failed: #{last_error}" unless QUIET
    rescue RubyLLM::Error, Faraday::Error => e
      last_error = e.message
      last_error_class = e.class.name
      warn "[#{label}] LLM error (#{last_error_class}): #{last_error}" unless QUIET
      waited = KotUtils.recover_from_llm_error(chat, e)
      if waited.positive? && (rate_waits += 1) <= KotUtils::MAX_RATE_WAITS
        attempts -= 1 # a rate limit is not a failed attempt
        warn "[#{label}] Waited #{waited}s after the rate limit (#{rate_waits}/#{KotUtils::MAX_RATE_WAITS}), trying again" unless QUIET
      end
    end
  end

  gaps ? [gaps, nil, nil] : [nil, last_error_class, last_error]
}

FIND_INFO_GAPS = ->(cid, prompt_path, target_path) {
  err_file = "#{target_path}.err"

  objects = INFO_OBJECTS.call(cid)
  object_ids = objects.map { |o| o["object_id"] }
  stories = INFO_GAPS_STORIES.call(cid)
  batch_count = (stories.size.to_f / INFO_GAPS_BATCH).ceil
  batches = stories.empty? ? [] : stories.each_slice((stories.size.to_f / batch_count).ceil).to_a

  gaps = []
  batches.each_with_index do |batch, k|
    label = (batches.size > 1) ? "#{cid} #{k + 1}/#{batches.size}" : cid
    thinking_key = (batches.size > 1) ? "#{target_path}.part#{k + 1}" : target_path
    user_prompt = INFO_GAPS_PROMPT.call(cid, objects, batch, prompt_path)
    found, error_class, error = INFO_GAPS_ASK.call(label, user_prompt, batch.map { |s| s["story_id"] }, object_ids, thinking_key)
    unless found
      File.write(err_file, "#{error_class}: #{error}\n")
      warn "[FAIL] #{label}: #{error_class}: #{error} (logged to #{err_file})"
      return
    end
    gaps.concat(found)
  end

  # No stories: an empty file, so that the component counts as checked.
  KotUtils.atomic_write(target_path) do |temp_file|
    File.open(temp_file, "w") { |f| gaps.each { |g| f.puts(JSON.generate(g)) } }
  end

  FileUtils.rm_f(err_file)
  KotUtils.clear_thinking(target_path)
  note = stories.empty? ? "no stories linked" : "#{stories.size} stories in #{batches.size} call(s), #{gaps.size} gaps"
  puts "[OK] #{target_path} (#{note})"
}

# PULL ARCHITECTURE: Define the target state
TARGET_INFO_GAPS_JSONLS = VALID_COMPONENT_IDS.map { |cid| "work/ta/#{cid}/#{cid}_info_gaps.jsonl" }

multitask :_all_info_gaps => TARGET_INFO_GAPS_JSONLS

desc "Stage 6b: information object gaps per component, report only (all: rake info_gaps, single: rake 'info_gaps[К-МД]')"
task :info_gaps, [:component_id] do |_, args|
  if args[:component_id]
    cid = args[:component_id]
    Rake::Task["work/ta/#{cid}/#{cid}_info_gaps.jsonl"].invoke
  else
    Rake::Task[:_all_info_gaps].invoke
  end
end

# THE RULE: aggregates + prompt + catalogue + the stories of the active
# processes -> info_gaps.jsonl. The frozen projections are read but not
# listed: as prerequisites they would pull in the stage 6 rule.
rule(%r{^work/ta/([^/]+)/\1_info_gaps\.jsonl$} => [
  proc { |t|
    cid = t.match(%r{work/ta/([^/]+)/})[1]
    "work/ta/#{cid}/#{cid}_aggregates.jsonl"
  },
  INFO_GAPS_PROMPT_FILE,
  COMPONENTS_FILE,
  *INFO_GAPS_STORY_FILES
]) do |t|
  cid = t.name.match(%r{work/ta/([^/]+)/})[1]
  FIND_INFO_GAPS.call(cid, INFO_GAPS_PROMPT_FILE, t.name)
end
