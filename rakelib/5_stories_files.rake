STORIES_PROMPT_FILE = "raw/prompts/extract_user_stories.txt"
STORIES_MODEL = ENV["STORIES_MODEL"] || "claude-sonnet-4-5"

# Build a lookup of full component definitions keyed by ID
COMPONENTS_CATALOG = File.foreach(COMPONENTS_FILE)
  .each_with_object({}) { |line, h|
    comp = JSON.parse(line)
    h[comp["ID"]] = comp
  }
  .freeze

VALIDATE_STORIES = ->(parsed_json, id, valid_roles, valid_component_ids) {
  stories = parsed_json.is_a?(Array) ? parsed_json : parsed_json["stories"]
  raise "Expected a JSON array of user stories" unless stories.is_a?(Array)
  raise "No user stories generated — every process should produce at least one" if stories.empty?

  role_id_to_name = valid_roles.each_with_object({}) { |r, h| h[r["role_id"]] = r["role"] }
  seen_story_ids = []

  stories.each_with_index do |story, i|
    # 1. Required keys
    %w[story_id role_id role content component_ids].each do |key|
      raise "Missing '#{key}' at index #{i}" unless story.key?(key)
    end

    # 2. story_id format: {process_id}-US-XX
    sid = story["story_id"]
    unless sid.match?(/\A#{Regexp.escape(id)}-US-\d{2,3}\z/)
      raise "Invalid story_id format '#{sid}' at index #{i}. Expected #{id}-US-XX"
    end
    if seen_story_ids.include?(sid)
      raise "Duplicate story_id '#{sid}' at index #{i}"
    end
    seen_story_ids << sid

    # 3. Role validation
    rid = story["role_id"]
    unless role_id_to_name.key?(rid)
      raise "Unknown role_id '#{rid}' at index #{i}. Valid: #{role_id_to_name.keys.join(", ")}"
    end
    expected_role = role_id_to_name[rid]
    unless story["role"] == expected_role
      raise "Role mismatch at index #{i}: role_id '#{rid}' expects role '#{expected_role}', got '#{story["role"]}'"
    end

    # 4. Content checks
    content = story["content"].to_s

    if content.match?(/\p{Han}/)
      raise "Chinese characters in content at index #{i}: '#{content[0..80]}'"
    end

    if content.match?(/(?!\p{Cyrillic}|\p{Latin})\p{L}/)
      raise "Invalid foreign characters in content at index #{i}: '#{content[0..80]}'"
    end

    unless content.match?(/\AКак\s/)
      raise "Content must start with 'Как ' at index #{i}: '#{content[0..40]}'"
    end

    raise "Content too short at index #{i} — must be a meaningful user story" if content.size < 30

    # 5. Component IDs validation
    cids = story["component_ids"]
    raise "component_ids must be a non-empty array at index #{i}" unless cids.is_a?(Array) && !cids.empty?

    cids.each do |cid|
      unless valid_component_ids.include?(cid)
        raise "Unknown component_id '#{cid}' in story '#{sid}'. Valid for this process: #{valid_component_ids.join(", ")}"
      end
    end
  end

  stories
}

EXTRACT_STORIES = ->(opis_path, roles_path, components_map_path, prompt_path, target_path) {
  id = target_path.match(%r{work/ba/([^/]+)/})[1]

  # 1. Load all inputs
  user_prompt_template = File.read(prompt_path, encoding: "UTF-8")
  opis_content = File.read(opis_path, encoding: "UTF-8")
  roles_content = File.read(roles_path, encoding: "UTF-8")

  # 2. Load mapped component IDs, then filter full catalog to get rich definitions
  mapped_component_ids = File.foreach(components_map_path)
    .map { |line| JSON.parse(line)["component_id"] }
    .to_a

  filtered_components = mapped_component_ids.filter_map { |cid|
    COMPONENTS_CATALOG[cid]&.to_json
  }.join("\n")

  # 3. Parse roles for validator
  valid_roles = File.foreach(roles_path).map { |line| JSON.parse(line) }.to_a

  # 4. Build prompt
  user_prompt = user_prompt_template % {process_id: id}
  user_prompt += "\n\n### ОПРЕДЕЛЁННЫЕ РОЛИ ПРОЦЕССА:\n#{roles_content}"
  user_prompt += "\n\n### РЕЛЕВАНТНЫЕ КОМПОНЕНТЫ СИСТЕМЫ:\n#{filtered_components}"
  user_prompt += "\n\n### ИСХОДНЫЙ ДОКУМЕНТ:\n#{opis_content}"

  system_prompt = %(
    You are an experienced business analyst with deep knowledge of Russian Arbitration Court processes and expertise in BPMN2 diagrams. You write in fluent and correct technical Russian only, except for technical terms.
  ).strip

  temperature = 0.3
  max_retries = 3

  unless QUIET
    prompt_chars = user_prompt.size
    warn "[#{id}] model=#{STORIES_MODEL} temp=#{temperature} roles=#{valid_roles.size} components=#{mapped_component_ids.size} prompt=#{prompt_chars} chars"
  end

  chat = RubyLLM.chat(
    model: STORIES_MODEL,
    provider: :anthropic,
    assume_model_exists: true
  ).with_instructions(system_prompt)
    .with_temperature(temperature)

  attempts = 0
  valid_stories = nil
  last_error = nil

  while attempts < max_retries && !valid_stories
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
      valid_stories = VALIDATE_STORIES.call(parsed_json, id, valid_roles, mapped_component_ids)
    rescue JSON::ParserError, RuntimeError => e
      last_error = e.message
      warn "[#{id}] Validation failed: #{last_error}" unless QUIET
    end
  end

  raise "[FAIL] #{id}: Could not generate valid user stories after #{max_retries} attempts. Last error: #{last_error}" unless valid_stories

  KotUtils.atomic_write(target_path) do |temp_file|
    File.open(temp_file, "w") do |f|
      valid_stories.each { |story| f.puts(story.to_json) }
    end
  end

  puts "[OK] #{target_path} (#{valid_stories.size} user stories)"
}

# PULL ARCHITECTURE: Define the target state
TARGET_STORY_JSONLS = PROCESS_IDS.map { |id| "work/ba/#{id}/#{id}_user_stories.jsonl" }

desc "Generate user stories with component links"
multitask stories: TARGET_STORY_JSONLS

# THE RULE: Maps target -> [opis.md, roles.jsonl, components.jsonl(mapped), prompt.txt]
rule(%r{^work/ba/([^/]+)/\1_user_stories\.jsonl$} => [
  proc do |t|
    id = t.match(%r{work/ba/([^/]+)/})[1]
    "work/ba/#{id}/#{id}_opis.md"
  end,
  proc do |t|
    id = t.match(%r{work/ba/([^/]+)/})[1]
    "work/ba/#{id}/#{id}_roles.jsonl"
  end,
  proc do |t|
    id = t.match(%r{work/ba/([^/]+)/})[1]
    "work/ba/#{id}/#{id}_components.jsonl"
  end,
  STORIES_PROMPT_FILE
]) do |t|
  opis_file = t.prerequisites[0]
  roles_file = t.prerequisites[1]
  components_map_file = t.prerequisites[2]
  prompt_file = t.prerequisites[3]

  EXTRACT_STORIES.call(opis_file, roles_file, components_map_file, prompt_file, t.name)
end
