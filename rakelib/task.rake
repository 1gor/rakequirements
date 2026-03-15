require_relative "../lib/kot_utils"

# Determine work directory - allows override for testing
WORK_DIR = ENV["RAKEQUIREMENTS_WORK_DIR"] || "."

desc "Extract process steps table from docx to CSV"
task :extract_steps, [:process_id] do |_t, args|
  process_id = args[:process_id]
  raise ArgumentError, "process_id is required" unless process_id

  puts ";; Extracting steps for process: #{process_id}"

  # Find the tobe docx file
  pattern = File.join(WORK_DIR, "raw", "processes", "#{process_id}_*", "*tobe*.docx")
  files = Dir.glob(pattern)

  if files.empty?
    raise "No matching 'tobe' file found for process_id '#{process_id}'. Pattern: #{pattern}"
  end

  source_file = files.first
  puts ";; Found source file: #{source_file}"

  # Define output paths
  output_dir = File.join(WORK_DIR, "work", process_id)
  csv_path = File.join(output_dir, "#{process_id}_steps.csv")
  error_path = File.join(output_dir, "#{process_id}_steps_error.md")

  # Ensure output directory exists
  FileUtils.mkdir_p(output_dir)

  # Use KotUtils to extract the table
  KotUtils.extract_steps_table(
    source_file: source_file,
    csv_path: csv_path,
    error_path: error_path
  )
end

namespace :extract_steps do
  desc "Extract steps for all processes"
  task :all do
    processes_dir = File.join(WORK_DIR, "raw", "processes")
    process_ids = Dir.glob(File.join(processes_dir, "*"))
                     .select { |d| File.directory?(d) }
                     .map { |d| File.basename(d).split("_").first }
                     .uniq

    puts ";; Found #{process_ids.size} processes"

    process_ids.each do |pid|
      puts ";; Processing #{pid}..."
      begin
        Rake::Task["extract_steps"].reenable
        Rake::Task["extract_steps"].invoke(pid)
      rescue => e
        puts ";; [Error] #{pid}: #{e.message}"
      end
    end
  end
end
