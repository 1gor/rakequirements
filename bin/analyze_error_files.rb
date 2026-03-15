#!/usr/bin/env ruby
require 'docx'

error_files = Dir.glob("work/*/*_error.md")

puts "Found #{error_files.count} error files"
puts "=" * 60

results = []

error_files.each do |error_file|
  process_id = File.basename(error_file).gsub("_steps_error.md", "")

  # Find source file
  pattern = "raw/processes/#{process_id}_*/*tobe*.docx"
  files = Dir.glob(pattern)

  if files.empty?
    results << { process_id: process_id, status: :no_source_file }
    next
  end

  source_file = files.first
  doc = Docx::Document.open(source_file)

  # Analyze all tables
  tables_info = doc.tables.map.with_index do |tbl, idx|
    next nil if tbl.rows.empty?

    header = tbl.rows[0].cells.map { |c| c.text.strip }
    row_count = tbl.rows.count

    # Check various heuristics
    header_text = header.join(" ").downcase

    {
      index: idx,
      rows: row_count,
      cols: header.count,
      headers: header.take(6),
      has_deystviya: header_text.include?("действия"),
      has_rol: header_text.include?("роль"),
      has_shag: header_text.include?("шаг"),
      has_zadacha: header_text.include?("задач"),
      has_naimenovanie: header_text.include?("наименован"),
      has_opisanie: header_text.include?("описан")
    }
  end.compact

  results << {
    process_id: process_id,
    source_file: source_file,
    table_count: doc.tables.count,
    tables: tables_info
  }
end

# Print summary
results.each do |r|
  puts "\n#{r[:process_id]}"
  puts "-" * 40

  if r[:status] == :no_source_file
    puts "  NO SOURCE FILE"
    next
  end

  puts "  Source: #{File.basename(r[:source_file])}"
  puts "  Tables: #{r[:table_count]}"

  r[:tables].each do |t|
    puts "  Table #{t[:index]}: #{t[:rows]} rows, #{t[:cols]} cols"
    puts "    Headers: #{t[:headers].join(' | ')[0..80]}"
    puts "    Flags: deystviya=#{t[:has_deystviya]}, rol=#{t[:has_rol]}, shag=#{t[:has_shag]}, zadacha=#{t[:has_zadacha]}"
  end
end
