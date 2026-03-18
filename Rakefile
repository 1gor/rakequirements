require "rake/clean"
require "standard/rake"

# Limit multitask parallelism (Z.ai concurrent request quota)
# Override with: rake -j 10
Rake.application.options.thread_pool_size = ENV.fetch("RAKE_JOBS", 4).to_i

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
