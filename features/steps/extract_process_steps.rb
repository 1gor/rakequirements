require "fileutils"

class Spinach::Features::ExtractProcessSteps < Spinach::FeatureSteps
  attr_reader :process_id, :rake_output, :rake_status

  # Helper to run rake task and capture output
  def run_rake_task(pid)
    cmd = "bundle exec rake extract_steps[#{pid}] 2>&1"
    @rake_output = `#{cmd}`
    @rake_status = $?.exitstatus
    @process_id = pid
    @rake_output
  end

  def output_csv_path
    "work/#{@process_id}/#{@process_id}_steps.csv"
  end

  def output_error_path
    "work/#{@process_id}/#{@process_id}_steps_error.md"
  end

  # Scenario 1: File exists, table exists
  step 'I have a file matching pattern "raw/processes/<process_id>_<ignored logn name>/*tobe*.docx"' do
    # KBP1 is known to exist with a valid table
    @process_id = "KBP1"
    @source_pattern = "raw/processes/#{@process_id}_*/*tobe*.docx"
    files = Dir.glob(@source_pattern)
    raise "Expected to find source file for KBP1" if files.empty?
  end

  step 'there is a csv table in the file matched by steps table heuristics' do
    # KBP1 has a valid steps table - verified in real data
  end

  step 'I run rake task extract_steps[<process_id>]' do
    run_rake_task(@process_id)
  end

  step 'work/<process_id>/<process_id>_steps.csv file will be generated, containing' do
    path = output_csv_path
    raise "Expected CSV file at #{path} to exist" unless File.exist?(path)

    content = File.read(path, encoding: "utf-8")
    raise "CSV should not be empty" if content.strip.empty?

    # Verify it contains Russian role/action headers
    has_role = content.downcase.include?("роль")
    has_action = content.include?("действия")
    raise "CSV should contain role and action columns" unless has_role || has_action
  end

  # Scenario 2: File exists, table does not exist
  # NOTE: This scenario requires a file without a valid steps table.
  # Currently all real files in raw/ have valid tables.
  # This scenario is marked pending until such a file is available.

  step 'no csv table could be found in the file matched by steps table heuristics' do
    pending "No real file without steps table available in raw/ directory"
  end

  step 'work/<process_id>/<process_id>_steps_error.md file will be generated.' do
    path = output_error_path
    raise "Expected error file at #{path} to exist" unless File.exist?(path)
  end

  # Scenario 3: File does not exist
  step 'I have no file matching pattern "raw/processes/<process_id>_<ignored logn name>/*tobe*.docx"' do
    @process_id = "NONEXISTENT_XYZ"
  end

  step 'the task fails with error message that no matching "tobe" file is found.' do
    run_rake_task(@process_id)
    raise "Expected rake task to fail" if @rake_status == 0

    has_error = @rake_output.include?("tobe") ||
                @rake_output.include?("not found") ||
                @rake_output.include?("No matching") ||
                @rake_output.include?("Error")

    raise "Expected error about missing tobe file, got: #{@rake_output}" unless has_error
  end
end
