# frozen_string_literal: true

require "json"

namespace :data do
  desc "Derive processes.jsonl (active processes) and processes-removed.jsonl from processes-all.jsonl. " \
       "OUT_DIR=dir writes both files elsewhere, to compare before replacing."
  task :filter_processes do
    all_path = "raw/data/processes-all.jsonl"
    out_dir = ENV.fetch("OUT_DIR", "raw/data")
    out_path = File.join(out_dir, "processes.jsonl")
    removed_path = File.join(out_dir, "processes-removed.jsonl")

    # Why a catalogued process is not active: its TOBE_* marker
    # (merged into another process, or dropped), or no TO BE document.
    removal_reason = lambda do |id|
      dir = Dir.glob("#{Sources::PROCESSES_DIR}/#{id}_*/").min
      next "папка процесса отсутствует" unless dir

      marker = Sources.tobe_marker(dir.chomp("/"))
      marker ? File.basename(marker) : "нет описания TO BE"
    end

    kept = []
    removed = []
    File.foreach(all_path) do |line|
      next if line.strip.empty?

      row = JSON.parse(line)
      if SOURCE_BY_ID.key?(row["process_id"])
        kept << row
      else
        removed << row.merge("reason" => removal_reason.call(row["process_id"]))
      end
    end

    missing = PROCESS_IDS - kept.map { |r| r["process_id"] }
    abort "Active processes missing from #{all_path}: #{missing.join(", ")}" unless missing.empty?

    FileUtils.mkdir_p(out_dir)
    File.open(out_path, "w") { |f| kept.each { |r| f.puts JSON.generate(r) } }
    File.open(removed_path, "w") { |f| removed.each { |r| f.puts JSON.generate(r) } }

    puts "  kept    #{kept.size} -> #{out_path}"
    puts "  removed #{removed.size} -> #{removed_path}"
  end
end
