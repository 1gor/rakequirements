# frozen_string_literal: true

require "zip"
require "nokogiri"
require "set"

# Audit of the text of a delivered .docx (no pipeline data, no LLM):
# characters that do not belong in a Russian document, and Latin (English)
# words inside Russian text. It reads the Word XML of the body, the tables,
# the headers, footers and notes.
module TextAudit
  module_function

  W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
  NS = {"w" => W}.freeze
  PARTS = %r{\Aword/(document|header\d*|footer\d*|footnotes|endnotes)\.xml\z}

  # --- Characters ----------------------------------------------------------

  # Characters a Russian document may contain. Anything else is reported.
  ALLOWED_CHAR = /[A-Za-z0-9А-Яа-яЁё !"#$%&'()*+,\-.\/:;<=>?@\[\\\]^_`{|}~\u00A0\u2009\u202F«»„“”‘’‚–—―\u2010\u2011…№§°±×÷•·‰€₽→←↑↓↔≤≥≠≈∞©®™]/

  def char_kind(c)
    case c
    when /[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}\u3000-\u303F\uFF00-\uFFEF]/ then "CJK"
    when /\p{Cyrillic}/ then "non-Russian Cyrillic"
    when /\p{Latin}/ then "accented Latin"
    when /[\u00AD\u200B-\u200F\u202A-\u202E\u2060-\u2064\u2066-\u2069\uFEFF]/ then "invisible"
    when /[\u0000-\u001F\u007F-\u009F]/ then "control"
    when /[\uE000-\uF8FF\uFFFD]/ then "private use or replacement"
    when /\p{L}/ then "other script"
    else "other symbol"
    end
  end

  # UTF-8 text decoded as a single-byte code page («Ð¡ÑƒÐ´», «â€”»)
  MOJIBAKE = /[\u00D0\u00D1\u00C3][\u0080-\u00BF]|\u00E2\u20AC/

  # Latin letters that look like Cyrillic ones
  LOOKALIKE_LOWER = "aceopxyk"
  LOOKALIKE_UPPER = "ABCEHKMOPTXY"

  # --- Latin words ---------------------------------------------------------

  # Codes of the KOT, masked before words are read
  CODES = {
    "process, story or role code" => /(?<![A-Za-z0-9])(?:KBP|TBP|OBP)\d+(?:-(?:US|R)-\d+)?(?![A-Za-z0-9])/,
    "participant code" => /(?<![A-Za-z0-9])P-\d{2}(?:\.\d+)?/,
    "object code" => /(?<![[:alpha:]])[КK]-[[:alpha:]]+(?:-[[:alpha:]]+)*?-(?:AG|PR)-\d{2}/,
    "use case code" => /(?<![A-Za-z])UC[-\s]?\d+/,
    "URL or e-mail" => %r{https?://[^\s«»"]+|www\.[^\s,;«»")]+|[\w.+-]+@[\w-]+(?:\.[\w-]+)+}
  }.freeze

  WORD = /[[:alnum:]]+(?:[-'’][[:alnum:]]+)*/

  def abbreviation?(token) = token.split("-").all? { |p| p.match?(/\A[A-Z0-9]*[A-Z][A-Z0-9]*s?\z/) } && token.count("A-Z") >= 2

  def identifier?(token) = token.split("-").any? { |p| p.match?(/[a-z][A-Z]|[A-Z]{2,}[a-z]|[A-Za-z]\d/) }

  # --- Reading the document ------------------------------------------------

  # Tables whose text is not ours to change, by their header row
  FROZEN_HEADERS = [
    ["Код компонента", "Наименование компонента", "Тип", "Реализуемые функции"],
    ["Код компонента", "Наименование компонента", "Технологии"],
    ["Назначение", "Технология"],
    ["Код объекта", "Наименование объекта", "Описание"],
    ["Код справочника", "Наименование справочника", "Описание"],
    ["Код матрицы", "Компонент", "Код компонента", "Информационный объект", "Код информационного объекта"],
    ["№ п/п", "Наименование компонента Системы", "Функции компонента Системы"]
  ].freeze
  STORIES_HEADER = ["Код пользовательской истории", "Я как", "Хочу", "Чтобы", "Код компонента"].freeze
  ROLES_HEADER = ["Код роли", "Роль", "Описание"].freeze
  PROCESSES_HEADER = ["Код процесса", "Наименование процесса", "Тип процесса", "Краткое описание"].freeze
  GENERATED_FIRST = ["Код участника", "Код матрицы"].freeze

  # Who wrote the text of a table cell: the analysts, the LLM, the May KOT...
  def origin(header, col)
    if header == STORIES_HEADER then col.between?(1, 3) ? "analysts verbatim" : "generated"
    elsif header == ROLES_HEADER then {1 => "role name", 2 => "role description (LLM)"}.fetch(col, "generated")
    elsif header == PROCESSES_HEADER then "process catalogue"
    elsif FROZEN_HEADERS.include?(header) then "frozen (May)"
    elsif GENERATED_FIRST.include?(header.first) then "generated"
    else "skeleton table"
    end
  end

  def text_of(p)
    p.xpath(".//w:t | .//w:tab | .//w:br | .//w:cr | .//w:noBreakHyphen", NS).map do |n|
      case n.name
      when "t" then n.text
      when "noBreakHyphen" then "-"
      else " "
      end
    end.join
  end

  def style_of(p) = p.at_xpath("./w:pPr/w:pStyle", NS)&.[]("w:val").to_s

  def each_block(node, &block)
    node.element_children.each do |c|
      if c.name == "sdt" then c.xpath("./w:sdtContent", NS).each { |sc| each_block(sc, &block) }
      elsif c.name == "p" || c.name == "tbl" then yield c
      end
    end
  end

  # Every visible paragraph: {text:, where:, origin:, header:, col:}
  def paragraphs(path)
    out = []
    Zip::File.open(path) do |zip|
      zip.entries.map(&:name).grep(PARTS).sort.each do |name|
        xml = Nokogiri::XML(zip.read(name))
        if name == "word/document.xml"
          read_body(xml, out)
        else
          part = File.basename(name, ".xml")
          xml.xpath("//w:p", NS).each { |p| out << {text: text_of(p), where: part, origin: "header, footer or notes"} }
        end
      end
    end
    out.reject { |p| p[:text].strip.empty? }
  end

  def read_body(xml, out)
    heading = []
    caption = nil
    index = 0
    uncaptioned = 0
    each_block(xml.at_xpath("/w:document/w:body", NS)) do |node|
      if node.name == "p"
        index += 1
        text = text_of(node)
        style = style_of(node)
        if (level = style[/\AHeading(\d)\z/, 1])
          heading = heading.first(level.to_i - 1) + [text.strip]
        end
        caption = text.strip if text.match?(/\AТаблица \d+\./)
        out << {text: text, where: "section «#{heading.last(2).join(" / ")}», paragraph #{index}",
                origin: style.match?(/\Atoc/i) ? "table of contents" : "skeleton text"}
      else
        label = caption ? caption[0, 70] : "table without caption #{uncaptioned += 1}"
        caption = nil
        read_table(node, label, out)
      end
    end
  end

  def read_table(tbl, label, out)
    rows = tbl.xpath("./w:tr", NS).map { |tr| tr.xpath("./w:tc", NS).map { |tc| tc.xpath(".//w:p", NS) } }
    header = rows.first.to_a.map { |ps| ps.map { |p| text_of(p) }.join(" ").strip }
    rows.each_with_index do |cells, r|
      key = cells.first.to_a.map { |p| text_of(p) }.join(" ").strip[0, 40]
      cells.each_with_index do |ps, col|
        part = nil # «Атрибуты» or «Правила» in the descriptions of table 10.1
        ps.each do |p|
          text = text_of(p)
          part = text.strip if %w[Атрибуты Правила].include?(text.strip)
          out << {text: text, header: header, col: col, part: part, origin: r.zero? ? "skeleton table" : origin(header, col),
                  where: "#{label}, row #{r.zero? ? "header" : "«#{key}»"}, column «#{header[col]}»"}
        end
      end
    end
  end

  # --- Checks --------------------------------------------------------------

  def context(text, from, len) = text[[from - 40, 0].max, len + 80].gsub(/\s+/, " ").strip

  # Findings of check (a): characters, mixed-script words, look-alike letters
  def character_findings(paras)
    findings = []
    paras.each do |p|
      text = p[:text]
      text.each_char.with_index do |c, i|
        next if c.match?(ALLOWED_CHAR)

        findings << {kind: char_kind(c), char: c, codepoint: format("U+%04X", c.ord), where: p[:where], origin: p[:origin], context: context(text, i, 1)}
      end
      text.scan(MOJIBAKE) { findings << {kind: "mojibake", char: $~[0], where: p[:where], origin: p[:origin], context: context(text, $~.begin(0), 2)} }
      latin_tokens(p) do |kind, token, at|
        next unless kind == :mixed

        findings << {kind: "Latin letter in a Russian word", char: token, where: p[:where], origin: p[:origin], context: context(text, at, token.size)}
      end
    end
    findings
  end

  # Yields [:code, name, offset], [:mixed, word, offset] or [:latin, token, offset]
  def latin_tokens(p)
    text = p[:text].dup
    CODES.each do |name, re|
      text.gsub!(re) do
        yield :code, name, $~.begin(0)
        " " * $~[0].size
      end
    end
    text.to_enum(:scan, WORD).each do
      word = $~[0]
      at = $~.begin(0)
      segs = word.split("-")
      scripts = segs.map { |s| [s.match?(/[A-Za-z]/), s.match?(/[А-Яа-яЁё]/)] }
      if scripts.any? { |lat, cyr| lat && cyr }
        yield :mixed, word, at
        next
      end
      latin = segs.each_index.select { |i| scripts[i][0] }
      next if latin.empty?

      if latin.size == 1 && segs[latin.first].size == 1 && scripts.any? { |_, cyr| cyr }
        yield :mixed, word, at # «K-СП»: a Latin letter joined to a Russian word
        next
      end
      latin.slice_when { |a, b| b != a + 1 }.each do |run|
        token = segs[run.first..run.last].join("-")
        token_at = at + segs[0...run.first].sum { |s| s.size + 1 }
        if token.size == 1 && lookalike?(token, text, at, word)
          yield :mixed, token, token_at
        else
          yield :latin, token, token_at
        end
      end
    end
  end

  # A lone Latin letter that may stand for a Cyrillic one («c» for «с»)
  def lookalike?(letter, text, at, word)
    return false unless word.size == 1
    return true if LOOKALIKE_LOWER.include?(letter)

    LOOKALIKE_UPPER.include?(letter) && !text[at + 1].to_s.match?(/[#+]/) && text[at + 1..].to_s.match?(/\A\s+[А-Яа-яЁё]/)
  end

  # Terms the document itself defines: technologies of the technology tables
  # and the matrix component/technology; names, attributes and attribute
  # values of table 10.1 (its «Правила» stay checked)
  def defined_terms(paras)
    terms = Set.new
    paras.each do |p|
      h = p[:header]
      tech = (h == ["Назначение", "Технология"] && p[:col] == 1) ||
        (h == ["Код компонента", "Наименование компонента", "Технологии"] && p[:col] == 2)
      object = h == ["Код объекта", "Наименование объекта", "Описание"] &&
        (p[:col] == 1 || (p[:col] == 2 && p[:part] == "Атрибуты"))
      next unless tech || object

      latin_tokens(p) { |kind, token, _| terms << token if kind == :latin }
    end
    terms
  end

  # Allowlist file: one token or phrase per line, «#» starts a comment
  def allowlist(path)
    return Set.new unless File.exist?(path)

    File.foreach(path).map { |l| l.sub(/#.*/, "").strip }.reject(&:empty?).to_set
  end

  def token_kind(token, allowed, defined, marked)
    if allowed.include?(token) then "allowlisted"
    elsif defined.include?(token) then "defined term"
    elsif marked then "marked as English (англ.)"
    elsif token.size == 1 then "single letter"
    elsif abbreviation?(token) then "abbreviation"
    elsif identifier?(token) then "identifier"
    else "word"
    end
  end

  # Findings of check (b). Latin tokens next to each other (only spaces or
  # hyphens between them) form a phrase; a phrase with a token of kind
  # «word» is a finding unless the whole phrase is in the allowlist.
  # Returns [phrases, tokens, codes, defined terms].
  def latin_findings(paras, allowed)
    defined = defined_terms(paras)
    phrases = []
    tokens = []
    codes = Hash.new(0)
    paras.each do |p|
      text = p[:text]
      marked = text.match?(/англ\./i)
      found = []
      latin_tokens(p) do |kind, token, at|
        codes[token] += 1 if kind == :code
        found << [token, at] if kind == :latin
      end
      found.slice_when { |(t, a), (_, b)| !text[a + t.size...b].to_s.match?(/\A[\s\-‐‑–]+\z/) }.each do |run|
        from = run.first[1]
        phrase = text[from...(run.last[1] + run.last[0].size)].gsub(/\s+/, " ")
        kinds = if allowed.include?(phrase) then ["allowlisted"] * run.size
        else run.map { |t, _| token_kind(t, allowed, defined, marked) }
        end
        run.zip(kinds).each { |(t, _), k| tokens << {token: t, kind: k, origin: p[:origin]} }
        next unless kinds.include?("word")

        gloss = text[0, from].count("(") > text[0, from].count(")")
        phrases << {phrase: phrase, gloss: gloss, where: p[:where], origin: p[:origin], context: context(text, from, phrase.size)}
      end
    end
    [phrases, tokens, codes, defined]
  end
end
