# lib/kot_utils.rb
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

  # The records of a .jsonl file, skipping blank lines.
  def read_jsonl(path)
    File.foreach(path, encoding: "UTF-8").reject { |line| line.strip.empty? }.map { |line| JSON.parse(line) }
  end

  # What came back when an LLM reply has no text: the stop reason, the content
  # block types and the token counts, for the .err file. A reply holding only a
  # thinking block with stop_reason "max_tokens" means the model spent its
  # whole output budget on reasoning. With a target, the reasoning is saved
  # to tmp/thinking/ (ignored by git) for reading why.
  def describe_empty_reply(msg, target_path = nil, attempt = nil)
    saved = target_path && save_thinking(msg, target_path, attempt)
    describe_reply_body(msg) + (saved ? ", saved to #{saved}" : "")
  end

  THINKING_DIR = "tmp/thinking"

  def thinking_path(target_path, attempt)
    File.join(THINKING_DIR, "#{File.basename(target_path)}.#{attempt}.md")
  end

  def save_thinking(msg, target_path, attempt)
    text = msg.thinking&.text.to_s
    return nil if text.empty?

    path = thinking_path(target_path, attempt || 1)
    FileUtils.mkdir_p(THINKING_DIR)
    File.write(path, text)
    path
  end

  # Removes the saved reasoning of a target once it has been built.
  def clear_thinking(target_path)
    FileUtils.rm_f(Dir.glob(thinking_path(target_path, "*")))
  end

  def describe_reply_body(msg)
    body = msg.raw.respond_to?(:body) ? msg.raw.body : nil
    if body.is_a?(String)
      body = begin
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end
    end
    body = {} unless body.is_a?(Hash)
    blocks = Array(body["content"]).map { |b| b.is_a?(Hash) ? b["type"] : b.class.name }
    "Empty reply: stop_reason=#{body["stop_reason"].inspect}, content blocks=#{blocks.inspect}, " \
      "output_tokens=#{msg.output_tokens.inspect}, thinking=#{msg.thinking&.text.to_s.size} chars"
  end

  # After an LLM error (no reply) the chat still holds the question that got
  # no answer, and the next ask would send it a second time. Drop it, then on
  # a rate limit wait before the next attempt. Z.ai error 1302 «Rate limit
  # reached for requests» is a short-term limit on requests, separate from the
  # 5-hour plan quota (1308/1316); ruby_llm has already retried three times
  # within a second. Returns the seconds waited (0 when nothing to wait for).
  def recover_from_llm_error(chat, error, attempt, max_attempts)
    chat.messages.pop if chat.messages.last&.role == :user
    return 0 unless error.is_a?(RubyLLM::RateLimitError) && attempt < max_attempts

    seconds = 30 * attempt + rand(15)
    sleep seconds
    seconds
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
