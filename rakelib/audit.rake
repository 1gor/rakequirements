# frozen_string_literal: true

require "json"
require "text_audit"

# Audit of the text of the delivered document (no LLM, no pipeline data):
#   rake audit:chars   characters that do not belong in a Russian document
#   rake audit:latin   Latin (English) words inside Russian text
# DOC selects the document (default out/kot_latest.docx, e.g. DOC=out/kot_2026-05-27.docx
# for the May KOT); reports go to out/audit/{document}_*.jsonl.
AUDIT_DOC = ENV.fetch("DOC", "out/kot_latest.docx")
AUDIT_DIR = ENV.fetch("AUDIT_DIR", "out/audit")
AUDIT_ALLOWLIST = "raw/data/audit_latin_allowlist.txt"

namespace :audit do
  paragraphs = nil
  read = -> { paragraphs ||= TextAudit.paragraphs(AUDIT_DOC).tap { |ps| puts "  #{AUDIT_DOC}: #{ps.size} paragraphs" } }
  report = ->(name) { File.join(AUDIT_DIR, "#{File.basename(AUDIT_DOC, ".docx")}_#{name}.jsonl") }
  write = lambda do |name, records|
    FileUtils.mkdir_p(AUDIT_DIR)
    File.open(report.call(name), "w") { |f| records.each { |r| f.puts(JSON.generate(r)) } }
    puts "  wrote #{report.call(name)}"
  end
  tally = ->(list) { list.tally.sort_by { |_, n| -n }.map { |k, n| "#{k} #{n}" }.join(", ") }

  desc "Audit the document for characters that do not belong in Russian text: CJK, other scripts, accented Latin, invisible and control characters, mojibake, Latin look-alike letters in Russian words"
  task :chars do
    findings = TextAudit.character_findings(read.call)
    if findings.empty?
      puts "  No invalid characters."
    else
      puts "  Invalid characters: #{findings.size}"
      findings.group_by { |f| f[:kind] }.sort_by { |_, v| -v.size }.each do |kind, fs|
        shown = fs.group_by { |f| f[:char] }.sort_by { |_, v| -v.size }.first(12).map do |c, v|
          label = v.first[:codepoint] ? "#{v.first[:codepoint]}#{c.match?(/[[:graph:]]/) && kind != "invisible" ? " #{c}" : ""}" : "«#{c}»"
          "#{label} ×#{v.size}"
        end
        puts "    #{kind}: #{fs.size} (#{shown.join(", ")})"
        puts "      in: #{tally.call(fs.map { |f| f[:origin] })}"
      end
    end
    write.call("characters", findings)
  end

  desc "Audit the document for Latin (English) words in Russian text; codes, abbreviations, identifiers, terms of the technology tables and table 10.1, and the reviewed tokens of #{AUDIT_ALLOWLIST} are allowed"
  task :latin do
    phrases, tokens, codes, defined = TextAudit.latin_findings(read.call, TextAudit.allowlist(AUDIT_ALLOWLIST))
    group = ->(ts) { {count: ts.size, origins: ts.map { |t| t[:origin] }.tally} }
    words = phrases.group_by { |ph| ph[:phrase] }.map do |phrase, ps|
      {token: phrase, **group.call(ps), in_brackets: ps.count { |ph| ph[:gloss] },
       where: ps.map { |ph| ph[:where] }.uniq.first(5), contexts: ps.map { |ph| ph[:context] }.uniq.first(3)}
    end.sort_by { |w| [-w[:count], w[:token]] }
    allowed = tokens.reject { |t| t[:kind] == "word" }.group_by { |t| [t[:kind], t[:token]] }.map do |(kind, token), ts|
      {token: token, kind: kind, **group.call(ts)}
    end.sort_by { |a| [a[:kind], -a[:count], a[:token]] }

    puts "  Codes (allowed): #{tally.call(codes.flat_map { |k, n| [k] * n })}"
    allowed.group_by { |a| a[:kind] }.each do |kind, as|
      top = as.sort_by { |a| -a[:count] }.first(15).map { |a| a[:token] }.join(", ")
      puts "  #{kind} (allowed): #{as.size} tokens, #{as.sum { |a| a[:count] }} times: #{top}#{as.size > 15 ? ", ..." : ""}"
    end
    puts "  Terms defined by the technology tables and table 10.1: #{defined.size}"
    if words.empty?
      puts "  No Latin words outside the exceptions."
    else
      puts "  Latin words to review: #{words.size} phrases, #{words.sum { |w| w[:count] }} times"
      puts "    in: #{tally.call(words.flat_map { |w| w[:origins].flat_map { |o, n| [o] * n } })}"
      words.first(40).each do |w|
        brackets = w[:in_brackets].positive? ? ", #{w[:in_brackets]} in brackets" : ""
        puts "    #{w[:token]} ×#{w[:count]} (#{w[:origins].keys.join(", ")}#{brackets}): #{w[:contexts].first}"
      end
      puts "    ... #{words.size - 40} more in the report" if words.size > 40
      puts "  Reviewed tokens or phrases that are fine go into #{AUDIT_ALLOWLIST}, one per line."
    end
    write.call("latin_words", words)
    write.call("latin_allowed", allowed)
  end

  desc "Run both text audits (audit:chars, audit:latin)"
  task text: %i[chars latin]
end
