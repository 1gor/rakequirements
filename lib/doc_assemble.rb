require "docx"
require "nokogiri"

module DocAssemble
  PLACEHOLDER_RE = /\{\{\s*(TABLE|REF):\s*([^}\s]+?)\s*\}\}/
  W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
  NS = {"w" => W}.freeze

  module_function

  def extract_table_xml(path)
    doc = Docx::Document.open(path)
    tbl = doc.doc.xpath("//w:tbl", NS).first
    raise "no <w:tbl> in #{path}" unless tbl
    tbl
  end

  TABLE_FONT_HALFPOINTS = 20  # 10pt

  def normalize_table!(tbl)
    tbl.xpath(".//w:p", NS).each { |p| force_paragraph_defaults!(p) }
    tbl.xpath(".//w:tr", NS).each { |tr| collapse_category_row!(tr) }
    tbl.xpath(".//w:r", NS).each { |r| force_run_font_size!(r, TABLE_FONT_HALFPOINTS) }
  end

  def force_run_font_size!(r, half_points)
    rPr = r.xpath("./w:rPr", NS).first
    unless rPr
      rPr = Nokogiri::XML::Node.new("w:rPr", r.document)
      r.prepend_child(rPr)
    end
    rPr.xpath("./w:sz", NS).each(&:remove)
    rPr.xpath("./w:szCs", NS).each(&:remove)
    sz = Nokogiri::XML::Node.new("w:sz", r.document)
    sz["w:val"] = half_points.to_s
    szCs = Nokogiri::XML::Node.new("w:szCs", r.document)
    szCs["w:val"] = half_points.to_s
    rPr.add_child(sz)
    rPr.add_child(szCs)
  end

  def force_paragraph_defaults!(p)
    pPr = p.xpath("./w:pPr", NS).first
    unless pPr
      pPr = Nokogiri::XML::Node.new("w:pPr", p.document)
      p.prepend_child(pPr)
    end
    pPr.xpath("./w:ind", NS).each(&:remove)
    pPr.xpath("./w:jc", NS).each(&:remove)
    ind = Nokogiri::XML::Node.new("w:ind", p.document)
    ind["w:left"] = "0"
    ind["w:right"] = "0"
    ind["w:firstLine"] = "0"
    jc = Nokogiri::XML::Node.new("w:jc", p.document)
    jc["w:val"] = "left"
    pPr.add_child(ind)
    pPr.add_child(jc)
  end

  def collapse_category_row!(tr)
    cells = tr.xpath("./w:tc", NS)
    return if cells.size < 2
    first_text = cells.first.xpath(".//w:t", NS).map(&:text).join.strip
    return if first_text.empty?
    rest_text = cells[1..].map { |tc| tc.xpath(".//w:t", NS).map(&:text).join.strip }.join
    return unless rest_text.empty?

    span = cells.size
    tcPr = cells.first.xpath("./w:tcPr", NS).first
    unless tcPr
      tcPr = Nokogiri::XML::Node.new("w:tcPr", tr.document)
      cells.first.prepend_child(tcPr)
    end
    tcPr.xpath("./w:gridSpan", NS).each(&:remove)
    gs = Nokogiri::XML::Node.new("w:gridSpan", tr.document)
    gs["w:val"] = span.to_s
    tcPr.prepend_child(gs)
    cells[1..].each(&:remove)
  end

  def build(template:, tables_dir:, out:)
    doc = Docx::Document.open(template)
    paragraphs = doc.paragraphs

    table_order = []
    paragraphs.each do |p|
      p.text.scan(PLACEHOLDER_RE) do |kind, slug|
        table_order << slug if kind == "TABLE" && !table_order.include?(slug)
      end
    end
    numbering = table_order.each_with_index.to_h { |s, i| [s, i + 1] }
    puts "table order: #{numbering.inspect}"

    paragraphs.each do |p|
      next unless p.text =~ PLACEHOLDER_RE
      text = p.text

      if text =~ /\A\s*\{\{\s*TABLE:\s*([^}\s]+)\s*\}\}\s*\z/
        slug = $1
        src = File.join(tables_dir, slug)
        src = "#{src}.docx" unless src.end_with?(".docx")
        tbl_xml = extract_table_xml(src).to_xml
        target_doc = p.node.document
        fragment = Nokogiri::XML.fragment(tbl_xml).children.first
        target_doc.root.add_child(fragment.dup)
        imported = target_doc.root.children.last
        normalize_table!(imported)
        p.node.add_next_sibling(imported)
        if p.node.xpath("./w:pPr/w:sectPr", NS).any?
          p.node.xpath("./w:r", NS).each(&:remove)
          imported.add_next_sibling(p.node)
          puts "spliced TABLE #{slug} (preserved section break)"
        else
          p.node.remove
          puts "spliced TABLE #{slug}"
        end
      elsif text =~ PLACEHOLDER_RE
        new_text = text.gsub(PLACEHOLDER_RE) do
          kind, slug = $1, $2
          if kind == "REF"
            n = numbering[slug] or raise "REF to unknown slug #{slug}"
            n.to_s
          else
            $~[0]
          end
        end
        p.node.xpath(".//w:t", "w" => "http://schemas.openxmlformats.org/wordprocessingml/2006/main").each(&:remove)
        first_r = p.node.xpath(".//w:r", "w" => "http://schemas.openxmlformats.org/wordprocessingml/2006/main").first
        if first_r
          t = Nokogiri::XML::Node.new("w:t", p.node.document)
          t.content = new_text
          first_r.add_child(t)
        end
        puts "rewrote REFs in paragraph: #{new_text[0, 60]}"
      end
    end

    doc.save(out)
    puts "wrote #{out}"
  end
end

if $PROGRAM_NAME == __FILE__
  DocAssemble.build(
    template: "out/kot_skeleton.docx",
    tables_dir: "out/tables",
    out: "out/kot_latest.docx"
  )
end
