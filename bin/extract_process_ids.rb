#!/usr/bin/env ruby
# frozen_string_literal: true

# Extracts short process_id from the combined id field and restructures JSONL
# Example: KBP1_iskovoe -> process_id: "KBP1", slug: "KBP1_iskovoe"

require 'json'

INPUT_FILE = 'raw/data/processes.jsonl'

def transform_row(row)
  old_id = row.delete('id')
  short_id = old_id.split('_').first

  # Build new row with process_id first
  { 'process_id' => short_id }.merge(row).merge('slug' => old_id)
end

def main
  lines = File.readlines(INPUT_FILE, chomp: true)

  File.open(INPUT_FILE, 'w') do |f|
    lines.each do |line|
      next if line.strip.empty?

      row = JSON.parse(line)
      transformed = transform_row(row)
      f.puts(JSON.generate(transformed))
    end
  end

  puts "Processed #{lines.size} rows"
end

main
