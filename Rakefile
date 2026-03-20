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

desc "Fix mtimes for a process directory (use after git checkout)"
task :fix_mtime, [:id] do |_, args|
  id = args[:id]
  dir = "work/ba/#{id}"
  # Touch in dependency order
  sh "touch #{dir}/#{id}_opis.md"
  sh "touch #{dir}/#{id}_roles.jsonl #{dir}/#{id}_components.jsonl #{dir}/#{id}_processes.jsonl"
  sh "touch #{dir}/#{id}_user_stories.jsonl"
end
