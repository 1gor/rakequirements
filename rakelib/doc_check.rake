# frozen_string_literal: true

require "docx"
require "set"

# Checks of the generated KOT tables in out/tables (no LLM): row counts against
# the approved May KOT, and the links between the registers and the matrices.
module DocCheck
  module_function

  MAY_KOT = "out/kot_2026-05-27.docx"

  # Tables of the technical design that the November KOT keeps as approved in
  # May (epic nov-kot): they must come out identical.
  FROZEN = %w[7_reestr_komponentov 8_matrica_komponent_tech 10-1_reestr_info_objektov_obyekty
    10-2_reestr_info_objektov_spravochniki 11_matrica_komponent_info 13_trebovaniya_funkcii].freeze

  TABLES = %w[1_reestr_uchastnikov 2_reestr_roley 3_matrica_uchastnik_rol 4_reestr_us 5_reestr_processov
    6_matrica_process_us 7_reestr_komponentov 8_matrica_komponent_tech 9_matrica_komponent_uchastnik
    10-1_reestr_info_objektov_obyekty 10-2_reestr_info_objektov_spravochniki 11_matrica_komponent_info
    12_matrica_us_komponent 13_trebovaniya_funkcii].freeze

  def path(slug) = "out/tables/#{slug}.docx"

  # A row as its cell texts, trailing empty cells dropped. The assembled KOT
  # merges a section row into one cell; out/tables keeps the empty cells.
  def cells(row) = row.cells.map { |c| c.text.strip }.reverse.drop_while(&:empty?).reverse

  def section?(cells, width) = width > 1 && cells.size <= 1

  # { header: [...], data: [[...]], sections: n } of one docx table
  def split(table)
    rows = table.rows.map { |r| cells(r) }
    header = rows.first
    body = rows.drop(1)
    sections, data = body.partition { |c| section?(c, header.size) }
    {header: header, data: data, sections: sections.size}
  end

  def load(slug) = split(Docx::Document.open(path(slug)).tables.first)

  # Data rows of a register or matrix, as column values
  def column(slug, index) = load(slug)[:data].map { |c| c[index].to_s }
end

namespace :doc do
  desc "Compare the row count of every KOT table in out/tables with the approved May KOT; the frozen tables must be identical"
  task :counts do
    missing = DocCheck::TABLES.reject { |s| File.exist?(DocCheck.path(s)) }
    abort "Missing tables (run rake doc:all): #{missing.join(", ")}" unless missing.empty?

    may = Docx::Document.open(DocCheck::MAY_KOT).tables.map { |t| DocCheck.split(t) }
    failures = []
    puts format("  %-42s %8s %8s %8s  %s", "table", "November", "May", "change", "rows")
    DocCheck::TABLES.each do |slug|
      nov = DocCheck.load(slug)
      ref = may.find { |t| t[:header] == nov[:header] }
      unless ref
        failures << "#{slug}: no table with the same header in #{DocCheck::MAY_KOT}"
        puts format("  %-42s %8d %8s", slug, nov[:data].size, "?")
        next
      end

      only_nov = (nov[:data] - ref[:data]).size
      only_may = (ref[:data] - nov[:data]).size
      same = only_nov.zero? && only_may.zero? && nov[:data] == ref[:data]
      text = same ? "identical" : "#{only_nov} new, #{only_may} gone"
      frozen = DocCheck::FROZEN.include?(slug)
      failures << "#{slug}: frozen but #{text}" if frozen && !same
      puts format("  %-42s %8d %8d %+8d  %s%s", slug, nov[:data].size, ref[:data].size,
        nov[:data].size - ref[:data].size, text, frozen ? " (frozen)" : "")
    end
    puts "  Matrix rows differ in their codes (М1.001...) when rows are added or removed before them."
    abort failures.map { |f| "[FAIL] #{f}" }.join("\n") unless failures.empty?
    puts "  Frozen tables identical to May."
  end

  desc "Check the links between the KOT registers and matrices in out/tables (every code a matrix uses is in its register)"
  task :links do
    missing = DocCheck::TABLES.reject { |s| File.exist?(DocCheck.path(s)) }
    abort "Missing tables (run rake doc:all): #{missing.join(", ")}" unless missing.empty?

    col = ->(slug, i) { DocCheck.column(slug, i) }
    participants = col.call("1_reestr_uchastnikov", 0)
    roles = col.call("2_reestr_roley", 0)
    stories = DocCheck.load("4_reestr_us")[:data].to_h { |c| [c[0], c[4].to_s.split(/,\s*/).sort] }
    processes = col.call("5_reestr_processov", 0)
    components = col.call("7_reestr_komponentov", 0)
    objects = col.call("10-1_reestr_info_objektov_obyekty", 0) + col.call("10-2_reestr_info_objektov_spravochniki", 0)
    m1 = DocCheck.load("3_matrica_uchastnik_rol")[:data].map { |c| [c[1], c[3]] }
    m2 = DocCheck.load("6_matrica_process_us")[:data].map { |c| [c[1], c[3]] }
    m4 = DocCheck.load("9_matrica_komponent_uchastnik")[:data].map { |c| [c[2], c[4]] }
    m5 = DocCheck.load("11_matrica_komponent_info")[:data].map { |c| [c[2], c[4]] }
    m6 = DocCheck.load("12_matrica_us_komponent")[:data].map { |c| [c[1], c[3]] }
    m8 = col.call("8_matrica_komponent_tech", 0)
    functions = DocCheck.load("13_trebovaniya_funkcii")[:data].size

    dups = ->(list) { list.tally.select { |_, n| n > 1 }.keys }
    unknown = ->(list, register) { (list - register).uniq }
    # Labels use the KOT table numbers of req/trebovaniya-k-sostavu-i-soderzhaniju.md
    story_counts = m2.map(&:last).tally
    object_counts = m5.map(&:last).tally
    components_of = m6.group_by(&:first).transform_values { |v| v.map(&:last).sort }
    checks = {
      "(1) participant codes unique" => dups.call(participants),
      "(2) role codes unique" => dups.call(roles),
      "(4) story codes unique" => dups.call(col.call("4_reestr_us", 0)),
      "(5) process codes unique" => dups.call(processes),
      "(7) component codes unique" => dups.call(components),
      "(10.1), (10.2) object codes unique" => dups.call(objects),
      "(3) participants in (1)" => unknown.call(m1.map(&:first), participants),
      "(3) roles in (2)" => unknown.call(m1.map(&:last), roles),
      "(2) roles in (3)" => roles - m1.map(&:last),
      "(3) one participant per role" => dups.call(m1.map(&:last)),
      "(4) components in (7)" => unknown.call(stories.values.flatten, components),
      "(6) processes in (5)" => unknown.call(m2.map(&:first), processes),
      "(6) stories in (4)" => unknown.call(m2.map(&:last), stories.keys),
      "(4) stories once in (6)" => stories.keys.reject { |s| story_counts[s] == 1 },
      "(5) processes in (6)" => processes - m2.map(&:first),
      "(6) story belongs to its process" => m2.reject { |p, s| s.start_with?("#{p}-") }.map { |p, s| "#{p}/#{s}" },
      "(9) components in (7)" => unknown.call(m4.map(&:first), components),
      "(9) participants in (1)" => unknown.call(m4.map(&:last), participants),
      "(9) pairs unique" => dups.call(m4).map { |c, p| "#{c}/#{p}" },
      "(11) components in (7)" => unknown.call(m5.map(&:first), components),
      "(11) objects in (10.1), (10.2)" => unknown.call(m5.map(&:last), objects),
      "(10.1), (10.2) objects once in (11)" => objects.reject { |o| object_counts[o] == 1 },
      "(11) object belongs to its component" => m5.reject { |c, o| o.start_with?("#{c}-") }.map { |c, o| "#{c}/#{o}" },
      "(12) stories in (4)" => unknown.call(m6.map(&:first), stories.keys),
      "(12) components in (7)" => unknown.call(m6.map(&:last), components),
      "(12) components equal the components of (4), per story" => stories.reject { |s, cs| components_of.fetch(s, []) == cs }.keys,
      "(8) components in (7)" => unknown.call(m8, components),
      "(13) one row per component of (7)" => (functions == components.size) ? [] : ["#{functions} rows, #{components.size} components"]
    }

    checks.each do |name, bad|
      puts bad.empty? ? "  [OK]   #{name}" : "  [FAIL] #{name}: #{bad.size} (#{bad.first(10).join(", ")}#{bad.size > 10 ? ", ..." : ""})"
    end
    none = ->(list) { list.empty? ? "none" : list.join(", ") }
    puts "  (1) participants in no row of (3): #{none.call(participants - m1.map(&:first))}"
    puts "  (7) components linked to no story in (12): #{none.call(components - m6.map(&:last))}"
    puts "  (7) components with no participant in (9): #{none.call(components - m4.map(&:first))}"
    failed = checks.count { |_, bad| !bad.empty? }
    abort "  #{failed} link checks failed" if failed.positive?
    puts "  All #{checks.size} link checks passed (#{stories.size} stories, #{m6.size} story-component links, #{m4.size} component-participant pairs)."
  end
end
