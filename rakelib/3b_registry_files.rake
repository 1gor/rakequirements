# frozen_string_literal: true

require "json"
require "kot_utils"
require "analyst_registry"

# Stage 3b: the analysts' «Реестр US» and «Реестр UC», read from opis.md
# without an LLM. The text stays verbatim; see lib/analyst_registry.rb.
#
#   work/ba/{id}/{id}_user_stories_src.jsonl  story_id, n_src, source, actor, want, in_order_to
#   work/ba/{id}/{id}_use_cases.jsonl         uc_id, title, fields
#
# An unchanged result is not rewritten, so its timestamp stays and the LLM
# stages that depend on it are not rebuilt (editing the supplement or the
# parser touches only the processes whose stories really change).

US_SUPPLEMENT_FILE = "raw/data/user_stories_supplement.jsonl"
ANALYST_REGISTRY_LIB = "lib/analyst_registry.rb"

WRITE_REGISTRY = ->(target, records, errors, warnings) {
  err_file = "#{target}.err"
  warn_file = "#{target}.warn"

  unless errors.empty?
    File.write(err_file, errors.join("\n") + "\n")
    warn "[FAIL] #{target}: #{errors.first} (#{errors.size} errors, logged to #{err_file})"
    return
  end

  FileUtils.rm_f(err_file)
  if warnings.empty?
    FileUtils.rm_f(warn_file)
  else
    File.write(warn_file, warnings.join("\n") + "\n")
  end

  content = records.map { |r| JSON.generate(r) + "\n" }.join
  note = warnings.empty? ? "" : ", #{warnings.size} warnings in #{warn_file}"
  # Unchanged: keep the old timestamp. The target then stays older than the
  # parser and is re-checked on every run, so this line is shown only on demand.
  if File.exist?(target) && File.read(target, encoding: "UTF-8") == content
    puts "[SAME] #{target} (#{records.size}#{note})" if ENV["VERBOSE"]
    return
  end

  KotUtils.atomic_write(target) { |tmp| File.write(tmp, content) }
  puts "[OK] #{target} (#{records.size}#{note})"
}

EXTRACT_USER_STORIES_SRC = ->(opis_path, target) {
  id = target[%r{work/ba/([^/]+)/}, 1]
  stories, errors, warnings = AnalystRegistry.user_stories(File.read(opis_path, encoding: "UTF-8"), id)

  extra = AnalystRegistry.supplement(US_SUPPLEMENT_FILE, id)
  extra.reject { |s| s["story_id"].match?(/\A#{id}-US-\d{2}\z/) }.each do |s|
    errors << "#{US_SUPPLEMENT_FILE}: story_id «#{s["story_id"]}» не в формате #{id}-US-NN"
  end
  clash = stories.map { |s| s["story_id"] } & extra.map { |s| s["story_id"] }
  errors << "#{US_SUPPLEMENT_FILE}: story_id совпадают с реестром US: #{clash.join(", ")}" unless clash.empty?
  stories += extra

  if stories.empty? && errors.empty?
    errors << "нет таблицы «Реестр US» (№ | Я КАК | ХОЧУ | ЧТОБЫ) или она пуста, и нет историй в #{US_SUPPLEMENT_FILE}"
  end

  WRITE_REGISTRY.call(target, stories, errors, warnings)
}

EXTRACT_USE_CASES = ->(opis_path, target) {
  use_cases, warnings = AnalystRegistry.use_cases(File.read(opis_path, encoding: "UTF-8"))
  WRITE_REGISTRY.call(target, use_cases, [], warnings)
}

OPIS_OF = proc do |t|
  id = t.match(%r{work/ba/([^/]+)/})[1]
  "work/ba/#{id}/#{id}_opis.md"
end

TARGET_US_SRC_JSONLS = PROCESS_IDS.map { |id| "work/ba/#{id}/#{id}_user_stories_src.jsonl" }
TARGET_UC_JSONLS = PROCESS_IDS.map { |id| "work/ba/#{id}/#{id}_use_cases.jsonl" }

desc "Stage 3b: read the analysts' user stories from opis.md (no LLM)"
multitask user_stories_src: TARGET_US_SRC_JSONLS

desc "Stage 3b: read the analysts' use cases from opis.md (no LLM)"
multitask use_cases: TARGET_UC_JSONLS

rule(%r{^work/ba/([^/]+)/\1_user_stories_src\.jsonl$} => [OPIS_OF, US_SUPPLEMENT_FILE, ANALYST_REGISTRY_LIB]) do |t|
  EXTRACT_USER_STORIES_SRC.call(t.prerequisites[0], t.name)
end

rule(%r{^work/ba/([^/]+)/\1_use_cases\.jsonl$} => [OPIS_OF, ANALYST_REGISTRY_LIB]) do |t|
  EXTRACT_USE_CASES.call(t.prerequisites[0], t.name)
end
