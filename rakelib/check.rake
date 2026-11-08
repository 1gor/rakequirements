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

  desc "Check stage 3 roles across processes: participants that differ by process or from the May KOT, compound actors split into fewer roles than they name"
  task :role_participants do
    output_path = "out/check_role_participants.jsonl"
    FileUtils.mkdir_p("out")

    precedents = File.foreach("raw/data/may_role_participants.jsonl").map { |l| JSON.parse(l) }
      .to_h { |r| [r["role"], r["participant_code"]] }
    roles = PROCESS_IDS.flat_map do |id|
      f = "work/ba/#{id}/#{id}_roles.jsonl"
      File.exist?(f) ? File.foreach(f).reject { |l| l.strip.empty? }.map { |l| [id, JSON.parse(l)] } : []
    end

    findings = []
    roles.group_by { |_, r| r["role"] }.sort.each do |name, rs|
      codes = rs.group_by { |_, r| r.dig("participant", "code") }.transform_values { |v| v.map(&:first) }
      findings << {kind: "разные участники", role: name, codes: codes} if codes.size > 1
      precedent = precedents[name]
      if precedent && codes.keys != [precedent]
        findings << {kind: "не как в КОТ мая", role: name, precedent: precedent, codes: codes}
      end
    end

    # A compound actor («А/Б/В», outside brackets) usually yields one role per
    # part; fewer roles may mean a part was dropped. Commas are not separators
    # («Лицо, участвующее в деле»), nor slashes in short abbreviations («с/з»).
    roles.group_by(&:first).each do |pid, prs|
      prs.flat_map { |_, r| (r["actors"] || []).map { |a| [a, r["role"]] } }.group_by(&:first).each do |actor, pairs|
        parts = actor.gsub(/\([^)]*\)|\[[^\]]*\]/, "").gsub(%r{(?<![[:alpha:]])([[:alpha:]]{1,2})/([[:alpha:]]{1,2})(?![[:alpha:]])}, '\1\2')
          .split(%r{[/;]}).map(&:strip).reject(&:empty?)
        next if parts.size <= pairs.size

        findings << {kind: "частей больше, чем ролей", process_id: pid, actor: actor, roles: pairs.map(&:last)}
      end
    end

    File.open(output_path, "w") { |f| findings.each { |r| f.puts(JSON.generate(r)) } }

    new_names = roles.map { |_, r| r["role"] }.uniq.reject { |n| precedents.key?(n) }
    puts "  Roles: #{roles.size} in #{roles.map(&:first).uniq.size} processes, #{new_names.size} names not in the May KOT"
    findings.group_by { |f| f[:kind] }.each { |kind, fs| puts "  #{kind}: #{fs.size}" }
    puts "  wrote #{output_path}"
  end

  desc "Collect the component gaps of the stage 8 review (stories whose need no catalogue component implements) and the components linked to no story"
  task :component_gaps do
    output_path = "out/check_component_gaps.jsonl"
    FileUtils.mkdir_p("out")
    read = ->(f) { File.foreach(f).reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) } }

    gaps = []
    not_reviewed = []
    stale = []
    linked = Hash.new(0)
    PROCESS_IDS.each do |id|
      review = "work/ba/#{id}/#{id}_components_review.jsonl"
      stories_file = "work/ba/#{id}/#{id}_user_stories.jsonl"
      stories = read.call(stories_file).to_h { |s| [s["story_id"], s] }
      stories.each_value { |s| s["component_ids"].each { |c| linked[c] += 1 } }
      next not_reviewed << id unless File.exist?(review) && !File.exist?("#{review}.err")
      next stale << id if File.mtime(review) < File.mtime(stories_file)

      read.call(review).select { |r| r.key?("need") }.each do |g|
        s = stories[g["story_id"]]
        gaps << g.merge("process_id" => id, "role" => s["role"], "want" => s["want"],
          "in_order_to" => s["in_order_to"], "component_ids" => s["component_ids"])
      end
    end

    File.open(output_path, "w") { |f| gaps.each { |g| f.puts(JSON.generate(g)) } }

    catalogue = File.foreach("raw/data/components.jsonl").map { |l| JSON.parse(l)["ID"] }
    puts "  Gaps: #{gaps.size} in #{gaps.map { |g| g["process_id"] }.uniq.size} processes"
    gaps.group_by { |g| g["closest_component_id"] }.sort_by { |_, v| -v.size }.each do |cid, v|
      puts "    closest #{cid}: #{v.size} (#{v.map { |g| g["story_id"] }.join(", ")})"
    end
    puts "  Not reviewed or failed: #{not_reviewed.join(", ")}" unless not_reviewed.empty?
    puts "  Review older than its stories (rerun rake review_components): #{stale.join(", ")}" unless stale.empty?
    puts "  Catalogue components linked to no story: #{(catalogue - linked.keys).join(", ")}"
    puts "  wrote #{output_path}"
  end

  desc "Run all quality checks"
  task all: %i[latin_in_stories latin_in_roles]
end
