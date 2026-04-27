# frozen_string_literal: true

require "json"

namespace :data do
  desc "Filter processes.jsonl: drop processes without _tobe_opis docs, log reasons to processes-removed.jsonl"
  task :filter_processes do
    all_path = "raw/data/processes-all.jsonl"
    out_path = "raw/data/processes.jsonl"
    removed_path = "raw/data/processes-removed.jsonl"

    kept = []
    removed = []

    File.foreach(all_path) do |line|
      line = line.strip
      next if line.empty?
      row = JSON.parse(line)
      slug = row["slug"]
      tobe_dir = File.join("raw/processes", slug, "tobe")

      unless Dir.exist?(tobe_dir)
        removed << row.merge("reason" => "директория #{tobe_dir} отсутствует")
        next
      end

      docs = Dir.glob(File.join(tobe_dir, "*.{docx,doc}")).select { |p| File.basename(p).include?("tobe") }
      if docs.any?
        kept << row
        next
      end

      txts = Dir.glob(File.join(tobe_dir, "*.txt")).map { |p| File.basename(p) }
      non_error = txts.reject { |n| n.include?("error") }
      reason = non_error.first || txts.first || "отсутствует tobe документ"
      removed << row.merge("reason" => reason)
    end

    File.open(out_path, "w") { |f| kept.each { |r| f.puts JSON.generate(r) } }
    File.open(removed_path, "w") { |f| removed.each { |r| f.puts JSON.generate(r) } }

    puts "  kept    #{kept.size} -> #{out_path}"
    puts "  removed #{removed.size} -> #{removed_path}"
  end
end
