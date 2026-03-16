require "fileutils"

PROCESS_MARKDOWN = ->(source, target) {
  FileUtils.mkdir_p(File.dirname(target))
  sh "markitdown #{source} > #{target} 2>/dev/null"
}

# STAGE 1: call it with `rake work/KBP1/KBP1_opis.md`
rule(%r{^work/([^/]+)/\1_opis\.md$} => [
  proc do |t|
    id = t.match(%r{work/([^/]+)/})[1]
    Sources.find_source_docx(id)
  end
]) do |t|
  PROCESS_MARKDOWN.call(t.source, t.name)
end
