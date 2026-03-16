require "fileutils"

PROCESS_MARKDOWN = ->(tobe, asis, target) {
  FileUtils.mkdir_p(File.dirname(target))
  success = (File.exist?(tobe) && system("markitdown", tobe, out: target, err: File::NULL)) ||
    (File.exist?(asis) && system("markitdown", asis, out: target, err: File::NULL))
  File.write(target, "ERROR_MISSING\n") unless success
}

# STAGE 1: The OPIS Rule (Same as before)
rule(%r{^work/([^/]+)/\1_opis\.md$} => [
  proc do |t|
    id = t.match(%r{work/([^/]+)/})[1]
    Dir["raw/#{id}/#{id}_*tobe*.docx"]
  end
]) do |t|
  id = t.name.match(%r{work/([^/]+)/})[1]
  source_file = Dir.glob("raw/processes/#{id}_*/#{id}*tobe*.docx").first
  PROCESS_MARKDOWN.call(source_file, "raw/#{id}/#{id}_asis.md", t.name)
end
