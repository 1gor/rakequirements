# frozen_string_literal: true

require "json"
require "set"

namespace :check do
  # Latin words that are legitimate technical terms and should not be flagged
  ALLOWED_LATIN = Set.new(%w[
    OCR LLM ASR PDF QR Email e-mail Word Excel ML API SMS MFC
    ERP CRM BPM BPMN DMS ECM ESB ETL SSO LDAP SAML OAuth
    Service Desk ID IP URL HTTP HTTPS REST SOAP JSON XML CSV
    SWIFT IBAN BIC ISO RFC GOST
  ].map(&:downcase))

  # Shared: scan text for bad Latin words
  def self.find_bad_latin(text)
    latin_words = text.scan(/[a-zA-Z]+(?:-[a-zA-Z]+)*/)
    latin_words.reject { |w|
      w.length < 2 ||
        ALLOWED_LATIN.include?(w.downcase) ||
        w.match?(/^(KBP|TBP|OBP|PR|US|R)\d*$/i) ||
        w.match?(/^[IVX]+$/)
    }
  end

  # Shared: scan text for Chinese/CJK characters
  def self.find_cjk(text)
    text.scan(/[\u4e00-\u9fff\u3400-\u4dbf\u{20000}-\u{2a6df}]+/)
  end

  desc "Check user stories for non-Russian text (Latin code-switching, Chinese)"
  task :latin_in_stories do
    output_path = "out/check_latin_in_stories.jsonl"
    FileUtils.mkdir_p("out")

    findings = []

    Dir.glob("work/ba/**/*_user_stories.jsonl").sort.each do |f|
      pid = File.basename(f).split("_").first
      File.foreach(f) do |line|
        next if line.strip.empty?
        story = JSON.parse(line)

        %w[role want in_order_to].each do |field|
          val = story[field]
          next unless val

          bad_latin = find_bad_latin(val)
          bad_cjk = find_cjk(val)
          next if bad_latin.empty? && bad_cjk.empty?

          finding = {process_id: pid, story_id: story["story_id"], field: field, text: val}
          finding[:latin_words] = bad_latin unless bad_latin.empty?
          finding[:cjk_chars] = bad_cjk unless bad_cjk.empty?
          findings << finding
        end
      end
    end

    File.open(output_path, "w") { |f| findings.each { |r| f.puts(r.to_json) } }

    if findings.empty?
      puts "  Stories: no issues found."
    else
      puts "  Stories: #{findings.size} issues in #{findings.map { |f| f[:process_id] }.uniq.size} processes"
      puts "  wrote #{output_path}"
    end
  end

  desc "Check roles for non-Russian text (Latin code-switching, Chinese)"
  task :latin_in_roles do
    output_path = "out/check_latin_in_roles.jsonl"
    FileUtils.mkdir_p("out")

    findings = []

    Dir.glob("work/ba/**/*_roles.jsonl").sort.each do |f|
      pid = File.basename(f).split("_").first
      File.foreach(f) do |line|
        next if line.strip.empty?
        role = JSON.parse(line)

        %w[role description].each do |field|
          val = role[field]
          next unless val

          bad_latin = find_bad_latin(val)
          bad_cjk = find_cjk(val)
          next if bad_latin.empty? && bad_cjk.empty?

          finding = {process_id: pid, role_id: role["role_id"], field: field, text: val}
          finding[:latin_words] = bad_latin unless bad_latin.empty?
          finding[:cjk_chars] = bad_cjk unless bad_cjk.empty?
          findings << finding
        end
      end
    end

    File.open(output_path, "w") { |f| findings.each { |r| f.puts(r.to_json) } }

    if findings.empty?
      puts "  Roles: no issues found."
    else
      puts "  Roles: #{findings.size} issues in #{findings.map { |f| f[:process_id] }.uniq.size} processes"
      puts "  wrote #{output_path}"
    end
  end

  desc "Run all quality checks"
  task all: %i[latin_in_stories latin_in_roles]
end
