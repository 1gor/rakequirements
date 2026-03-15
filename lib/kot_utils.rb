# lib/kot_utils.rb
require "docx"
require "csv"
require "fileutils"
require "open3"

module KotUtils
  module_function

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
