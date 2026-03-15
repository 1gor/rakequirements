require_relative "../lib/kot_utils"

# Determine work directory - allows override for testing
WORK_DIR = ENV["RAKEQUIREMENTS_WORK_DIR"] || "."

desc "Extract process steps table from docx to CSV"
task :extract_steps, [:process_id] do |_t, args|
  process_id = args[:process_id]
  raise ArgumentError, "process_id is required" unless process_id

  puts ";; Extracting steps for process: #{process_id}"

  # Find the tobe docx file
  tobe_pattern = File.join(WORK_DIR, "raw", "processes", "#{process_id}_*", "*tobe*.docx")
  tobe_files = Dir.glob(tobe_pattern)

  if tobe_files.empty?
    raise "No matching 'tobe' file found for process_id '#{process_id}'. Pattern: #{tobe_pattern}"
  end

  tobe_file = tobe_files.first
  puts ";; Found tobe file: #{tobe_file}"

  # Find the asis docx file (fallback)
  asis_pattern = File.join(WORK_DIR, "raw", "processes", "#{process_id}_*", "*asis*.docx")
  asis_files = Dir.glob(asis_pattern)
  asis_file = asis_files.first

  if asis_file
    puts ";; Found asis fallback: #{asis_file}"
  else
    puts ";; No asis fallback available"
  end

  # Define output paths
  output_dir = File.join(WORK_DIR, "work", process_id)
  csv_path = File.join(output_dir, "#{process_id}_steps.csv")
  error_path = File.join(output_dir, "#{process_id}_error_finding_steps_table.md")
  from_asis_path = File.join(output_dir, "#{process_id}_steps_from_asis.md")

  # Ensure output directory exists
  FileUtils.mkdir_p(output_dir)

  # Use KotUtils to extract the table with fallback
  if asis_file
    KotUtils.extract_steps_table_with_fallback(
      tobe_file: tobe_file,
      asis_file: asis_file,
      csv_path: csv_path,
      error_path: error_path,
      from_asis_path: from_asis_path
    )
  else
    # No asis fallback - use simple extraction
    KotUtils.extract_steps_table(
      source_file: tobe_file,
      csv_path: csv_path,
      error_path: error_path
    )
  end
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
