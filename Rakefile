require "rake/clean"
require "standard/rake"

$LOAD_PATH << "lib"
require "sources"
require "fileutils"
require "open3"

desc "Foo"
task :foo do
  p IDS
end

desc "Bar"
task :source_docx, [:id] do |_, args|
  p Sources.find_source_docx(args[:id])
end
