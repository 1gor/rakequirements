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

  desc "Check user stories for non-Russian text (Latin code-switching)"
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

          # Find Latin letter sequences of 2+ chars (including hyphenated like e-mail)
          latin_words = val.scan(/[a-zA-Z]+(?:-[a-zA-Z]+)*/)
          # Reject known technical terms, single chars, and ID-like patterns
          bad = latin_words.reject { |w|
            w.length < 2 ||
              ALLOWED_LATIN.include?(w.downcase) ||
              w.match?(/^(KBP|TBP|OBP|PR|US|R)\d*$/i) ||
              w.match?(/^[IVX]+$/) # Roman numerals
          }

          next if bad.empty?

          findings << {
            process_id: pid,
            story_id: story["story_id"],
            field: field,
            latin_words: bad,
            text: val
          }
        end
      end
    end

    File.open(output_path, "w") do |f|
      findings.each { |r| f.puts(r.to_json) }
    end

    if findings.empty?
      puts "  No Latin code-switching found."
    else
      puts "  Found #{findings.size} issues in #{findings.map { |f| f[:process_id] }.uniq.size} processes"
      puts "  wrote #{output_path}"
    end
  end
end
