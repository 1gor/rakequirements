require "json"
require "fileutils"

SOURCE = "raw/data/components.jsonl"
TA_DIR = "work/ta"
SLIM_OUTPUT = "raw/data/components_slim.jsonl"

FileUtils.mkdir_p(TA_DIR)

File.open(SLIM_OUTPUT, "w:UTF-8") do |slim_file|
  File.foreach(SOURCE, encoding: "UTF-8") do |line|
    next if line.strip.empty?
    comp = JSON.parse(line)

    cid = comp["ID"]
    comp_dir = File.join(TA_DIR, cid)
    FileUtils.mkdir_p(comp_dir)

    # Extract aggregate with embedded vocabulary
    if agg = comp["Aggregate"]
      new_agg = agg.merge(
        "component_id" => cid,
        "UbiquitousVocabulary" => comp["UbiquitousVocabulary"] || {}
      )

      agg_file = File.join(comp_dir, "#{cid}_aggregates.jsonl")
      File.open(agg_file, "a:UTF-8") { |f| f.puts(JSON.generate(new_agg)) }
      puts "[OK] #{cid}: extracted aggregate"
    end

    # Write slim catalog entry
    slim = {
      "ID" => cid,
      "Type" => comp["Type"],
      "Наименование компонента" => comp["Наименование компонента"],
      "Описание реализуемых функций" => comp["Описание реализуемых функций"]
    }
    slim_file.puts(JSON.generate(slim))
  end
end

puts "\nDone!"
puts "Slim catalog: #{SLIM_OUTPUT}"
puts "TA directory: #{TA_DIR}/"
puts "\nVerify, then: mv #{SLIM_OUTPUT} #{SOURCE}"
