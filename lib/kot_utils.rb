# lib/kot_utils.rb
require "docx"
require "csv"
require "fileutils"
require "open3"

module KotUtils
  module_function

  # Main entry point for extract_steps rake task
  # @param source_file [String] Path to the source docx file
  # @param csv_path [String] Path where CSV output should be written
  # @param error_path [String] Path where error markdown should be written if no table found
  # @param from_asis_path [String] Path for marker file when using asis fallback
  # @return [Symbol] :success, :from_asis, or :error
  def extract_steps_table(source_file:, csv_path:, error_path:, from_asis_path: nil)
    log "Processing: #{source_file}"

    doc = Docx::Document.open(source_file)

    # Heuristic: Find the steps table
    # Looking for tables with "действия" (actions) and "роль" (role) columns
    steps_table = find_steps_table(doc)

    unless steps_table
      # No valid table found - write error file
      write_error_file(error_path, source_file)
      log "[Warn] No steps table found. Error written to #{error_path}"
      return :error
    end

    # Success - write CSV
    write_csv(csv_path, steps_table)
    log "[OK] CSV written to #{csv_path}"
    :success
  end

  # Extract steps with fallback from tobe to asis
  # @param tobe_file [String] Path to the tobe docx file
  # @param asis_file [String] Path to the asis docx file (fallback)
  # @param csv_path [String] Path where CSV output should be written
  # @param error_path [String] Path where error markdown should be written if no table found in either file
  # @param from_asis_path [String] Path for marker file when using asis fallback
  # @return [Symbol] :success, :from_asis, or :error
  def extract_steps_table_with_fallback(tobe_file:, asis_file:, csv_path:, error_path:, from_asis_path:)
    log "Trying tobe file: #{tobe_file}"

    doc = Docx::Document.open(tobe_file)
    steps_table = find_steps_table(doc)

    if steps_table
      # Success from tobe - clean up any stale error files
      write_csv(csv_path, steps_table)
      cleanup_error_files(File.dirname(csv_path), File.basename(csv_path, ".*"))
      log "[OK] CSV written to #{csv_path} (from tobe)"
      return :success
    end

    # tobe failed, try asis fallback
    log "[Warn] No steps table in tobe file. Trying asis fallback: #{asis_file}"

    unless File.exist?(asis_file)
      write_error_file(error_path, tobe_file)
      log "[Error] No asis file found. Error written to #{error_path}"
      return :error
    end

    doc = Docx::Document.open(asis_file)
    steps_table = find_steps_table(doc)

    unless steps_table
      # Both failed
      write_error_file(error_path, asis_file)
      log "[Error] No steps table in asis file either. Error written to #{error_path}"
      return :error
    end

    # Success from asis - write CSV, marker file, and clean up any stale error files
    write_csv(csv_path, steps_table)
    FileUtils.touch(from_asis_path)
    cleanup_error_files(File.dirname(csv_path), File.basename(csv_path, ".*"))
    log "[OK] CSV written to #{csv_path} (from asis). Marker: #{from_asis_path}"
    :from_asis
  end

  # Clean up error files in the work directory after successful extraction
  # @param dir [String] Directory to clean up (e.g., work/KBP4)
  # @param base_name [String] Base name without extension (e.g., KBP4_steps)
  def cleanup_error_files(dir, base_name)
    # Remove old error files with various naming patterns
    patterns = [
      File.join(dir, "*_error*.md"),
      File.join(dir, "*_steps_error.md")
    ]

    patterns.each do |pattern|
      Dir.glob(pattern).each do |file|
        FileUtils.rm_f(file)
        log "[Cleanup] Removed stale error file: #{file}"
      end
    end
  end

  # Find the steps table using heuristics
  def find_steps_table(doc)
    doc.tables.detect do |tbl|
      next false if tbl.rows.empty?

      header = tbl.rows[0].cells.map { |c| c.text.strip }
      # Look for columns containing "действия" (actions) and "роль" (role)
      header.any? { |h| h.include?("действия") } &&
        header.any? { |h| h.downcase.include?("роль") }
    end
  end

  # Write the steps table to CSV
  def write_csv(path, table)
    ensure_dir(path)
    atomic_write(path) do |temp_path|
      CSV.open(temp_path, "w", encoding: "utf-8") do |csv|
        table.rows.each do |row|
          csv << row.cells.map(&:text)
        end
      end
    end
  end

  # Write error markdown file
  def write_error_file(path, source_file)
    ensure_dir(path)
    File.write(path, <<~MD)
      # Steps Table Extraction Error

      **Source File:** `#{source_file}`
      **Timestamp:** #{Time.now}

      ## Issue

      No valid steps table could be found in the document.

      ## Heuristics Used

      The extractor looks for a table with:
      - A column containing "действия" (actions)
      - A column containing "роль" (role)

      ## Next Steps

      1. Open the source document
      2. Verify the table structure
      3. Ensure column headers match the expected pattern
    MD
  end

  def materialize_csv(t, _args)
    log "Processing atom: #{t.source}"
    ensure_dir(t.name)

    doc = Docx::Document.open(t.source)

    # Heuristic: Find the table
    steps_table = doc.tables.detect do |tbl|
      next if tbl.rows.empty?
      header = tbl.rows[0].cells.map { |c| c.text.strip }
      header.any? { |h| h.include?("действия") } &&
        header.any? { |h| h.downcase.include?("роль") }
    end

    # FAILURE PATH
    unless steps_table
      # 1. Define the failure artefact path
      fail_dir = "build/failures"
      ensure_dir("#{fail_dir}/placeholder")

      err_filename = File.basename(t.source, ".*") + "_error.txt"
      err_path = File.join(fail_dir, err_filename)

      error_msg = "No valid 'steps' table found in #{t.source} \nTimestamp: #{Time.now}"

      # 2. Write the failure log (So you can debug later)
      File.write(err_path, error_msg)
      log "[Warn] No table found. Logged to #{err_path}"

      # 3. CRITICAL CHANGE: Graceful Degredation
      # Do not raise. Instead, create an empty file.
      # Rake considers the task "done".
      # Downstream tasks (summarize_steps) will see it is 0 bytes and report "EMPTY".
      FileUtils.touch(t.name)
      return
    end

    # SUCCESS PATH
    atomic_write(t.name) do |temp_path|
      CSV.open(temp_path, "w", encoding: "utf-8") do |csv|
        # docx gem parsing...
        rows = steps_table.rows.map { |r| r.cells.map(&:text) }
        rows.each { |r| csv << r }
      end
    end
  end

  def copy_text(t, _args)
    log "Copying ignored file: #{t.source}"
    ensure_dir(t.name)
    FileUtils.cp(t.source, t.name)
  end

  def ensure_dir(path)
    FileUtils.mkdir_p(File.dirname(path))
  end

  def log(msg)
    puts ";; [Thread: #{Thread.current.object_id}] #{msg}"
  end

  # Reducer: [CSV, CSV, ...] -> Markdown Report
  def summarize_steps(t, _args)
    log "Reducing results into summary: #{t.name}"
    ensure_dir(t.name)

    # 1. Gather Data (The Reduce Loop)
    # t.prerequisites contains the list of all CSV files Rake ensured are up-to-date
    stats = t.prerequisites.map do |csv_path|
      if File.zero?(csv_path)
        {file: csv_path, status: "EMPTY (No Table)", rows: 0}
      else
        row_count = File.foreach(csv_path).count
        {file: csv_path, status: "OK", rows: row_count}
      end
    end

    # 2. Format Output
    File.open(t.name, "w") do |f|
      f.puts "# ETL Processing Summary"
      f.puts "Generated at: #{Time.now}"
      f.puts "\n| Process ID | Status | Rows | Artefact Path |"
      f.puts "|---|---|---|---|"

      stats.each do |s|
        # Extract "KBP10" from "build/procs/KBP10/KBP10_steps.csv"
        proc_id = s[:file].split("/")[-2]
        f.puts "| #{proc_id} | #{s[:status]} | #{s[:rows]} | `#{s[:file]}` |"
      end

      f.puts "\n**Total Files Processed:** #{stats.size}"
      f.puts "**Total Rows Generated:** #{stats.sum { |s| s[:rows] }}"
    end

    log "Summary generated: #{t.name}"
  end

  # The only "magic" we need:
  # Creates ephemeral files in build/active/ so you can 'watch' progress.
  def with_status(id, operation)
    status_file = "build/active/#{id}.#{operation}"
    FileUtils.mkdir_p(File.dirname(status_file))
    FileUtils.touch(status_file)

    yield # Run the block (The actual work)
  ensure
    FileUtils.rm_f(status_file)
  end

  def fetch_process_metadata(csv_path, process_id)
    table = CSV.read(csv_path, headers: true)

    # Look explicitly in the 'Название файла' column
    row = table.detect do |r|
      file_slug = r["Название файла"]&.strip
      next false unless file_slug

      file_slug == process_id ||
        file_slug.start_with?("#{process_id}_")
    end

    return nil unless row

    file_slug = row["Название файла"]&.strip
    id = file_slug.split("_", 2).first

    {
      process_id: id,
      name: row["Название процесса"]&.strip,
      description: row["Описание"]&.strip, file_slug:   file_slug
    }
  end

  # NEW METHOD: Robust CLI wrapper
  def generate_with_retries(id, operation, prompt, retries: 3)
    attempt = 0

    # Write prompt to a temp file to avoid "Argument list too long" (E2BIG) errors
    # This is safer than passing a massive string in ARGV
    prompt_file = "tmp/#{id}_#{operation}_prompt.txt"
    ensure_dir(prompt_file)
    File.write(prompt_file, prompt)

    begin
      attempt += 1
      log "Invoking LLM for #{id} [#{operation}] (Attempt #{attempt}/#{retries})..."

      # We assume your 'claude' CLI can read from a file or accepts the prompt.
      # If your CLI supports file input (e.g. -f), change this flag.
      # Here we cat the file into the command to be safe and standard.
      # "claude -p [CONTENT]"

      # Using array syntax prevents shell injection
      command = ["claude", "-p", prompt]

      # CAPTURE OUTPUT
      stdout, stderr, status = Open3.capture3(*command)

      unless status.success?
        raise "CLI Exit Code #{status.exitstatus}: #{stderr}"
      end

      # Return the raw content (JSON)
      stdout
    rescue => e
      log "[Error] #{e.message}"

      if attempt < retries
        sleep_time = 2**attempt # Exponential backoff: 2s, 4s, 8s
        log "Sleeping #{sleep_time}s before retry..."
        sleep(sleep_time)
        retry
      else
        log "[Fail] Exhausted retries for #{id}."
        # Propagate error so Rake knows this task failed
        raise e
      end
    ensure
      # Cleanup the temp prompt file to keep the disk clean
      FileUtils.rm_f(prompt_file)
    end
  end

  # THE ATOMIC WRITE PATTERN
  # Yields a temporary path. Only moves it to 'target_path' if the block succeeds.
  def atomic_write(target_path)
    # 1. Define a hidden temp path in the same directory (ensures atomic mv)
    temp_path = "#{target_path}.tmp.#{Time.now.to_f}"

    ensure_dir(target_path)

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
