require "fileutils"
require_relative "../../lib/kot_utils"

class Spinach::Features::ExtractRelatedProcesses < Spinach::FeatureSteps
  attr_reader :process_id, :opis_path, :related_codes, :output_path, :result

  step 'the file exists that relates to process <procedd_id> being analysed' do
    # Use KBP10 as test fixture - it has an opis.md file
    @process_id = 'KBP10'
    @opis_path = "work/#{@process_id}/#{@process_id}_opis.md"

    raise "Expected #{@opis_path} to exist" unless File.exist?(@opis_path)
  end

  step 'the file contains (sub) process codes such as KBP<...>, TBP<...> or OBP<...> that are **different** from <procedd_id>' do
    # Read the opis.md and verify it contains other process codes
    content = File.read(@opis_path)

    # KBP10's opis.md should contain TBP codes like TBP7, TBP53, etc.
    @related_codes = KotUtils.extract_process_codes(content, exclude: @process_id)

    raise "Expected to find related process codes" if @related_codes.empty?
  end

  step 'work/<process_id>/<procedd_id>_opis.md will be searched for related process codes, and using this code relevant lines will be extracted from work/<process_id>/<procedd_id>_opis.md and a new files with main process <process_id> will be in the first line with its <process_id>, <name>, <description> fields, followed by lines for each of the related processes, also in <process_id>, <name>, <description> format.' do
    # Run the extraction
    @output_path = "work/#{@process_id}/#{@process_id}_processes.json"

    # Call the utility method
    @result = KotUtils.extract_related_processes(process_id: @process_id, work_dir: '.')

    # Verify output file exists
    raise "Expected #{@output_path} to exist" unless File.exist?(@output_path)

    # Verify result is an array
    raise "Expected result to be an Array" unless @result.is_a?(Array)

    # Verify first entry is the main process
    raise "Expected first entry process_id to be #{@process_id}" unless @result.first['process_id'] == @process_id
    raise "Expected first entry to have 'name' key" unless @result.first.key?('name')
    raise "Expected first entry to have 'description' key" unless @result.first.key?('description')

    # Verify we have more than just the main process
    raise "Expected more than 1 process (main + related)" unless @result.size > 1

    # Verify all entries have required fields
    @result.each do |entry|
      expected_keys = ['description', 'name', 'process_id']
      raise "Expected keys #{expected_keys}, got #{entry.keys.sort}" unless entry.keys.sort == expected_keys
    end

    # Verify related processes are different from main
    @result[1..].each do |entry|
      raise "Expected related process_id to differ from #{@process_id}" if entry['process_id'] == @process_id
    end
  end
end
