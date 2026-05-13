# frozen_string_literal: true

require_relative "../lib/doc_assemble"

SKELETON = "out/kot_skeleton.docx"
ASSEMBLED = "out/kot_latest.docx"
TABLES_DIR = "out/tables"

file ASSEMBLED => [SKELETON, *FileList["#{TABLES_DIR}/*.docx"]] do
  DocAssemble.build(template: SKELETON, tables_dir: TABLES_DIR, out: ASSEMBLED)
end

namespace :doc do
  desc "Assemble final document from skeleton + tables -> #{ASSEMBLED}"
  task assemble: ASSEMBLED

  desc "Force re-assembly even if up-to-date"
  task :reassemble do
    rm_f ASSEMBLED
    Rake::Task[ASSEMBLED].invoke
  end
end
