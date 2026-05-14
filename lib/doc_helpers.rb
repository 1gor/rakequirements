# frozen_string_literal: true

require "json"
require "caracal"

module DocHelpers
  module_function

  PROCESS_TYPE_ORDER = %w[K T O].freeze
  PROCESS_TYPE_NAMES = {
    "K" => "Ключевые бизнес-процессы",
    "T" => "Типовые бизнес-процессы",
    "O" => "Обеспечивающие бизнес-процессы"
  }.freeze
  PROCESS_TYPE_FULL = {
    "K" => "Ключевой",
    "T" => "Типовой",
    "O" => "Обеспечивающий"
  }.freeze

  TABLE_STYLE = lambda { |tbl|
    tbl.border_line   :single
    tbl.border_size   4
    tbl.border_spacing 4
  }

  # Sort process IDs: KBP before TBP before OBP, then numeric
  def sort_process_ids(ids)
    ids.sort_by do |id|
      prefix = id[0]
      num = id[/\d+/].to_i
      [PROCESS_TYPE_ORDER.index(prefix) || 99, num]
    end
  end

  # Load all JSONL files matching a glob, yielding (process_id, parsed_object) or returning array
  def load_all_jsonl(glob_pattern)
    results = []
    Dir.glob(glob_pattern).each do |f|
      id = File.basename(f).split("_").first
      File.foreach(f) do |line|
        next if line.strip.empty?
        obj = JSON.parse(line)
        results << [id, obj]
      end
    end
    results
  end

  # Load components catalog as hash { ID => record }
  def load_components
    @components ||= begin
      h = {}
      File.foreach("raw/data/components.jsonl") do |line|
        obj = JSON.parse(line)
        h[obj["ID"]] = obj
      end
      h
    end
  end

  # Load processes catalog as hash { process_id => record }
  def load_processes
    @processes ||= begin
      h = {}
      File.foreach("raw/data/processes.jsonl") do |line|
        obj = JSON.parse(line)
        h[obj["process_id"]] = obj
      end
      h
    end
  end

  # Build header row cells with grey background and bold.
  # widths (optional) is an array of twip widths per column; Caracal derives
  # <w:tblGrid> from the first row's cell widths.
  def header_row(headers, widths = nil)
    headers.each_with_index.map do |h, i|
      cell = {content: h, bold: true, background: "cccccc"}
      cell[:width] = widths[i] if widths
      cell
    end
  end

  # Build a section header row (bold first cell, rest empty) spanning visual width
  def section_header_row(text, col_count)
    [{content: text, bold: true}] + Array.new(col_count - 1, "")
  end

  # Format user story as full sentence
  def story_text(story)
    "Я как #{story["role"]} хочу #{story["want"]}, чтобы #{story["in_order_to"]}"
  end

  # Ensure output directory exists
  def ensure_output_dir
    FileUtils.mkdir_p("out/tables")
  end
end
