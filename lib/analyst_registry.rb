# frozen_string_literal: true

require "json"

# Reads the analysts' «Реестр US» and «Реестр UC» tables from an opis.md
# (markitdown output of a TO BE description). The text is kept verbatim:
# only Markdown emphasis and escapes are removed and whitespace is collapsed.
module AnalystRegistry
  module_function

  ACTOR_HEADER = /\A(я[[:space:]]*как|роль)\z/i
  WANT_HEADER = /\A(я[[:space:]]*)?хочу\z/i
  SO_HEADER = /\Aчтобы\z/i
  UC_REGISTRY_HEADING = /Реестр[[:space:]]+UC/i
  # Ruby's \W counts Cyrillic letters as non-word characters, so the
  # patterns below use POSIX classes, which are Unicode-aware.
  UC_HEADING = /\A[^[:alnum:]]*(UC[-[:space:]]?\d+)[[:space:]]*[.\-—–:]*[[:space:]]*(.*?)[[:space:].:*—–-]*\z/
  # Characters markitdown escapes with a backslash.
  ESCAPABLE = "\\`*_{}[]()#+-.!|<>~"

  # Cell text without Markdown: escaped characters are restored, unescaped
  # asterisks (emphasis) are dropped, any other backslash stays (TBP80 has
  # «с\з», typed by the analyst).
  def plain(text)
    text.gsub(/\\(.)|\*/) do
      if $1.nil? then ""
      elsif ESCAPABLE.include?($1) then $1
      else "\\#{$1}"
      end
    end.gsub(/[[:space:]]+/, " ").strip
  end

  def cells(line)
    s = line.strip
    s = s[1..] if s.start_with?("|")
    s = s[0...-1] if s.end_with?("|") && !s.end_with?("\\|")
    s.split(/(?<!\\)\|/, -1).map { |c| plain(c) }
  end

  def table_row?(line)
    line.lstrip.start_with?("|")
  end

  def separator?(cells)
    cells.all? { |c| c.match?(/\A[-: ]*\z/) }
  end

  # The process code a story number may carry, in Latin script
  # («KBP57-US-01», «КБП57-US-01» → "KBP57").
  def number_pid(number)
    m = number.match(/\A(KBP|TBP|OBP|КБП|ТБП|ОБП)[[:space:]]?(\d+)/i) or return nil
    m[1].upcase.tr("КТОБП", "KTOBP") + m[2]
  end

  # Stories of one process.
  # Returns [stories, errors, warnings]; any error means the result is unusable.
  def user_stories(markdown, pid)
    lines = markdown.lines(chomp: true)
    errors = []
    warnings = []

    head = lines.index do |l|
      next false unless table_row?(l)

      c = cells(l)
      c.size >= 4 && c[1].match?(ACTOR_HEADER) && c[2].match?(WANT_HEADER) && c[3].match?(SO_HEADER)
    end
    return [[], [], []] if head.nil?

    stories = []
    lines[(head + 1)..].take_while { |l| table_row?(l) }.each do |line|
      c = cells(line)
      next if separator?(c) || c.all?(&:empty?)

      number, actor, want, so, *extra = c
      row = "строка «#{line.strip[0, 80]}»"
      if c.size < 4
        errors << "#{row}: #{c.size} колонок вместо 4"
        next
      end
      warnings << "#{row}: лишние колонки отброшены: #{extra.reject(&:empty?).join(" | ")}" if extra.any? { |x| !x.empty? }

      n = number[/(\d+)\.?\z/, 1]
      if n.nil?
        errors << "#{row}: номер US «#{number}» не распознан"
        next
      end
      if (other = number_pid(number)) && other != pid
        warnings << "#{row}: номер «#{number}» относится к #{other}, а не к #{pid}"
      end

      empty = {"Я КАК" => actor, "ХОЧУ" => want, "ЧТОБЫ" => so}.select { |_, v| v.match?(/\A[-—–]?\z/) }.keys
      errors << "US #{number}: пустое поле #{empty.join(", ")}" unless empty.empty?

      stories << {
        "story_id" => format("%s-US-%02d", pid, n.to_i),
        "n_src" => number,
        "source" => "opis",
        "actor" => actor,
        "want" => want,
        "in_order_to" => so
      }
    end

    stories.group_by { |s| s["story_id"] }.each do |id, group|
      errors << "#{id} встречается #{group.size} раза (номера: #{group.map { |s| s["n_src"] }.join(", ")})" if group.size > 1
    end
    numbers = stories.map { |s| s["story_id"][/\d+\z/].to_i }
    unless numbers.empty? || numbers == (1..numbers.size).to_a
      warnings << "номера US идут не подряд с 1: #{stories.map { |s| s["n_src"] }.join(", ")}"
    end

    [stories, errors, warnings]
  end

  # Use cases of one process, as written. Returns [use_cases, warnings].
  def use_cases(markdown)
    lines = markdown.lines(chomp: true)
    start = lines.index { |l| l.match?(UC_REGISTRY_HEADING) }
    return [[], []] if start.nil?

    use_cases = []
    warnings = []
    current = nil
    lines[(start + 1)..].each do |line|
      if table_row?(line)
        next if current.nil?

        c = cells(line)
        next if c.size < 2 || c[0].empty? || separator?(c) || c[0] == "Поле"

        current["fields"][c[0]] = c[1..].reject(&:empty?).join(" | ")
        next
      end

      heading = line.start_with?("#")
      text = plain(heading ? line.sub(/\A#+/, "") : line)
      next if text.empty?

      if (m = text.match(UC_HEADING))
        current = {"uc_id" => m[1].delete(" "), "title" => m[2], "fields" => {}}
        use_cases << current
      elsif heading
        break
      end
    end

    use_cases.group_by { |u| u["uc_id"] }.each do |id, group|
      warnings << "#{id} встречается #{group.size} раза" if group.size > 1
    end
    use_cases.select { |u| u["fields"].empty? }.each { |u| warnings << "#{u["uc_id"]}: нет таблицы полей" }

    [use_cases, warnings]
  end

  PASSPORT_KEYS = ["Наименование процесса", "Суть процесса", "Участники процесса"].freeze

  # The passport table at the top of the description, { key => value } for
  # PASSPORT_KEYS. ТБП5 and ТБП32 have no passport; the result is then empty.
  def passport(markdown)
    markdown.lines(chomp: true).first(15).select { |l| table_row?(l) }.each_with_object({}) do |line, h|
      key, value = cells(line)
      h[key] = value if PASSPORT_KEYS.include?(key) && value && !value.empty?
    end
  end

  # The document title without the «[To be] КБП61.» prefix.
  def title(markdown)
    line = markdown.lines(chomp: true).find { |l| l.start_with?("# ") } or return ""
    plain(line.sub(/\A#+/, "")).sub(/\A(\[[^\]]*\][[:space:]]*)?(KBP|TBP|OBP|КБП|ТБП|ОБП)[[:space:]]?\d+[[:space:].:—–-]*/i, "")
  end

  # Hand-kept stories for processes whose registry is empty
  # (raw/data/user_stories_supplement.jsonl), as story records.
  def supplement(path, pid)
    return [] unless File.exist?(path)

    File.foreach(path).reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }
      .select { |r| r["process_id"] == pid }
      .map do |r|
        {
          "story_id" => r.fetch("story_id"),
          "n_src" => nil,
          "source" => "supplement",
          "actor" => r.fetch("actor"),
          "want" => r.fetch("want"),
          "in_order_to" => r.fetch("in_order_to")
        }
      end
  end
end
