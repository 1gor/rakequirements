require "fileutils"
require "open3"

PROCESS_MARKDOWN = ->(source, target) {
  # 1. Safety check: What if the source docx doesn't exist?
  if source.nil? || !File.exist?(source.to_s)
    warn "[SKIP] No source document found for #{target}"
    return
  end

  FileUtils.mkdir_p(File.dirname(target))
  err_file = "#{target}.err"

  stdout_str, stderr_str, status = Open3.capture3("markitdown", source)

  if status.success?
    File.write(target, stdout_str)
    FileUtils.rm_f(err_file)

    # 2. The visual cue for success.
    # Notice we do this AFTER the file is successfully written.
    puts "[OK] #{target}"
  else
    File.write(err_file, stderr_str)

    # 3. The visual cue for failure. Used `warn` to send to STDERR.
    warn "[FAIL] #{source} (Exit: #{status.exitstatus})"
  end
}

# 1. PULL ARCHITECTURE: Define the target state
TARGET_MDS = PROCESS_IDS.map { |id| "work/#{id}/#{id}_opis.md" }

desc "Build all OPIS markdown files"
multitask opis_mds: TARGET_MDS

# 2. THE RULE: Resolve the dependency and execute
rule(%r{^work/([^/]+)/\1_opis\.md$} => [
  proc do |t|
    id = t.match(%r{work/([^/]+)/})[1]
    Sources.find_source_docx(id)
  end
]) do |t|
  PROCESS_MARKDOWN.call(t.source, t.name)
end

# 3. CROSS-PLATFORM STATUS DASHBOARD
# Since we can't rely on standard Unix `find` on Windows, let Rake do the work.
desc "Show build failures"
task :status do
  # FileList is pure Ruby, works on Windows and Linux
  failures = FileList["work/**/*.err"]

  if failures.empty?
    puts "Build is clean. No errors."
  else
    puts "Found #{failures.size} failed conversions:"
    failures.each do |err_file|
      puts " - #{err_file}"
      # Optional: print the first line of the error to give context
      puts "   Reason: #{begin
        File.foreach(err_file).first.strip
      rescue
        "Unknown"
      end}"
    end
  end
end
