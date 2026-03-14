require "rake/clean"
require "standard/rake"
require "fileutils"

module SDLC
  module_function

  def extract_id(filename)
    File.basename(filename).split("_").first
  end

  # The mapping function Rake uses to find the source for a target
  def find_source_docx(target_csv)
    id = extract_id(target_csv)
    # Find the _tobe_opis.docx anywhere in the raw directory
    Dir.glob("raw/processes/#{id}_*/#{id}_*_tobe_opis.docx").first
  end
end

SOURCE_DOCS = FileList["raw/processes/**/*tobe*.docx"]
IDS = SOURCE_DOCS.map { |f| SDLC.extract_id(f) }
        .group_by { |n| n[0] }
        .values.flatten
        # .compact.uniq

desc "Foo"
task :foo do
  p IDS
end
