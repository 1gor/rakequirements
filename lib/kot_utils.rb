# lib/kot_utils.rb
require "docx"
require "csv"
require "fileutils"
require "open3"
require "json"

module KotUtils
  module_function

  # Extract related processes from opis.md and create JSON context file
  # @param process_id [String] The main process ID (e.g., "KBP10")
  # @param work_dir [String] The working directory
  # @return [Array<Hash>] Array of process hashes with process_id, name, description
  def extract_related_processes(process_id:, work_dir:)
    # Paths
    opis_path = File.join(work_dir, "work", process_id, "#{process_id}_opis.md")
    processes_jsonl_path = File.join(work_dir, "raw", "data", "processes.jsonl")
    output_path = File.join(work_dir, "work", process_id, "#{process_id}_processes.json")

    unless File.exist?(opis_path)
      raise "opis.md file not found: #{opis_path}"
    end

    # Load process metadata lookup
    processes_lookup = load_processes_lookup(processes_jsonl_path)

    # Get main process info
    main_process = processes_lookup[process_id]
    unless main_process
      raise "Main process not found in processes.jsonl: #{process_id}"
    end

    # Find related process IDs in opis.md
    opis_content = File.read(opis_path)
    related_ids = extract_process_codes(opis_content, exclude: process_id)

    # Build result array: main process first, then related processes
    result = [main_process.slice("process_id", "name", "description")]

    related_ids.sort.each do |related_id|
      if (related_process = processes_lookup[related_id])
        result << related_process.slice("process_id", "name", "description")
      else
        log "[Warn] Related process not found in processes.jsonl: #{related_id}"
      end
    end

    # Write output as JSON array
    ensure_dir(output_path)
    File.write(output_path, JSON.pretty_generate(result))
    log "[OK] Written #{result.size} processes to #{output_path}"

    result
  end

  # Load processes.jsonl into a lookup hash keyed by process_id
  # @param path [String] Path to processes.jsonl
  # @return [Hash] Lookup hash with process_id as key
  def load_processes_lookup(path)
    lookup = {}
    File.foreach(path) do |line|
      next if line.strip.empty?
      row = JSON.parse(line)
      lookup[row["process_id"]] = row
    end
    lookup
  end

  # Extract unique process codes (KBP*, TBP*, OBP*) from text
  # @param text [String] Text to search
  # @param exclude [String] Process ID to exclude
  # @return [Array<String>] Unique sorted array of process IDs
  def extract_process_codes(text, exclude:)
    # Match patterns like KBP10, ТБП7, TBP53, OBP37, etc.
    # Both Cyrillic (КБП, ТБП, ОБП) and Latin (KBP, TBP, OBP) variants
    codes = []

    # Use gsub with block to capture and normalize codes
    text.gsub(/(?:KBP|КБП|TBP|ТБП|OBP|ОБП)\d+/i) do |match|
      # Normalize to Latin uppercase prefix
      code = match.upcase
        .gsub("КБП", "KBP")
        .gsub("ТБП", "TBP")
        .gsub("ОБП", "OBP")
      codes << code
    end

    codes.uniq.sort.reject { |code| code == exclude }
  end


  # THE ATOMIC WRITE PATTERN
  # Yields a temporary path. Only moves it to 'target_path' if the block succeeds.
  def atomic_write(target_path)
    # 1. Define a hidden temp path in the same directory (ensures atomic mv)
    temp_path = "#{target_path}.tmp.#{Time.now.to_f}"

    FileUtils.mkdir_p(File.dirname(target_path))

    begin
      # 2. Let the caller write to the temp file
      yield temp_path

      # 3. ATOMIC COMMIT: Rename temp to target
      # If the block raised an error, this line is never reached.
      FileUtils.mv(temp_path, target_path)
    ensure
      # 4. Cleanup: If something failed, kill the zombie temp file
      FileUtils.rm_f(temp_path) if File.exist?(temp_path)
    end
  end
end
