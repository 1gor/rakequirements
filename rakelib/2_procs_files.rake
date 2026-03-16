require "kot_utils" # Ensure this path is correct for your setup

PROCESSES_DICT = "raw/data/processes.jsonl"

# Pure lambda: Input files -> Transformation -> Output file
EXTRACT_PROCESSES = ->(opis_path, dict_path, target_path) {
  id = target_path.match(%r{work/([^/]+)/})[1]

  # 1. Load dependencies into memory
  opis_content = File.read(opis_path)
  lookup = KotUtils.load_processes_lookup(dict_path)

  main_process = lookup[id]
  unless main_process
    warn "[SKIP] Main process #{id} not found in dictionary"
    return
  end

  # 2. Extract and match logic
  related_ids = KotUtils.extract_process_codes(opis_content, exclude: id)

  rows = [main_process.slice("process_id", "name", "description")]
  related_ids.each do |rid|
    if (related = lookup[rid])
      rows << related.slice("process_id", "name", "description")
    else
      warn "[WARN] #{id}: Related process #{rid} found in #{id} but missing in dict"
    end
  end

  # 3. Write to disk using the Atomic Write pattern.
  # This guarantees a crashed process won't poison the build cache with a half-written file.
  KotUtils.atomic_write(target_path) do |temp_file|
    File.open(temp_file, "w") do |f|
      rows.each { |row| f.puts(row.to_json) }
    end
  end

  puts "[OK] #{target_path} (#{rows.size} processes)"
}

# 1. PULL ARCHITECTURE: Define the target state
TARGET_JSONLS = PROCESS_IDS.map { |id| "work/#{id}/#{id}_processes.jsonl" }

desc "Extract related processes into JSONL context files"
multitask processes_jsonls: TARGET_JSONLS

# 2. THE RULE: Maps target -> [opis.md, processes.jsonl]
rule(%r{^work/([^/]+)/\1_processes\.jsonl$} => [
  proc do |t|
    id = t.match(%r{work/([^/]+)/})[1]
    "work/#{id}/#{id}_opis.md"
  end,
  PROCESSES_DICT
]) do |t|
  # t.prerequisites contains our resolved dynamic file AND our static dictionary
  opis_file = t.prerequisites[0]
  dict_file = t.prerequisites[1]

  EXTRACT_PROCESSES.call(opis_file, dict_file, t.name)
end
