# frozen_string_literal: true

require "json"
require "open3"
require "set"
require "kot_utils"

namespace :spell do
  PERSONAL_DICT = "raw/data/spell_personal.dic"
  HUNSPELL_LANG = ENV.fetch("HUNSPELL_LANG", "ru_RU")

  # Persistent hunspell pipe — spawning it per call was the bottleneck.
  class HunspellPipe
    def initialize(lang:, personal_dict: nil)
      cmd = ["hunspell", "-d", lang, "-i", "utf-8", "-a"]
      cmd += ["-p", File.expand_path(personal_dict)] if personal_dict && File.exist?(personal_dict)
      @stdin, @stdout, @wait = Open3.popen2(*cmd)
      @stdout.gets  # consume banner
    end

    # Returns array of {word:, offset:, suggestions:[]} for one input line.
    def check(text)
      return [] if text.nil? || text.strip.empty?
      @stdin.puts("^#{text.tr("\n", " ")}")
      @stdin.flush

      misses = []
      while (line = @stdout.gets)
        line = line.chomp
        break if line.empty?
        case line
        when /\A& (\S+) \d+ (\d+): (.+)\z/
          misses << {word: $1, offset: $2.to_i - 1, suggestions: $3.split(", ")}
        when /\A# (\S+) (\d+)\z/
          misses << {word: $1, offset: $2.to_i - 1, suggestions: []}
        end
      end
      misses
    end

    def close
      @stdin.close rescue nil
      @stdout.close rescue nil
      Process.wait(@wait.pid) rescue nil
    end
  end

  def self.highlight(text, offset, word)
    pre = text[0, offset]
    hit = text[offset, word.length]
    post = text[offset + word.length..]
    "#{pre}\e[1;33m#{hit}\e[0m#{post}"
  end

  def self.add_to_personal_dict(word)
    FileUtils.mkdir_p(File.dirname(PERSONAL_DICT))
    File.open(PERSONAL_DICT, "a") { |f| f.puts(word) }
  end

  def self.prompt(record_id, field, text, miss)
    puts
    puts "  id:     #{record_id}  (#{field})"
    puts "  text:   #{highlight(text, miss[:offset], miss[:word])}"
    puts "  word:   \e[1;31m#{miss[:word]}\e[0m"
    if miss[:suggestions].empty?
      puts "  (no suggestions)"
    else
      miss[:suggestions].each_with_index do |s, i|
        puts "    #{i + 1}) #{s}"
      end
    end
    print "  [1-#{miss[:suggestions].size}] replace, (e)dit, (s)kip, (a)dd to dict, (q)uit > "
    $stdout.flush
    ans = $stdin.gets&.strip
    return [:quit] if ans.nil?

    case ans
    when "", "s" then [:skip]
    when "q" then [:quit]
    when "a"
      add_to_personal_dict(miss[:word])
      [:add]
    when "e"
      print "  new word > "
      $stdout.flush
      new_word = $stdin.gets&.strip
      (new_word.nil? || new_word.empty?) ? [:skip] : [:replace, new_word]
    when /\A\d+\z/
      idx = ans.to_i - 1
      if (sug = miss[:suggestions][idx])
        [:replace, sug]
      else
        puts "  invalid choice, skipping"
        [:skip]
      end
    else
      puts "  unknown action, skipping"
      [:skip]
    end
  end

  def self.replace_at(text, offset, word, replacement)
    text[0, offset] + replacement + text[offset + word.length..]
  end

  # Core driver shared by every spell:* task.
  def self.run_spellcheck(glob:, fields:, id_key:, prefix:)
    files = Dir.glob(glob).sort
    files.select! { |f| File.basename(f).start_with?(prefix) } unless prefix.empty?

    if files.empty?
      puts "no files match prefix #{prefix.inspect}"
      return
    end

    puts "spellchecking #{files.size} file(s)#{prefix.empty? ? "" : " (prefix: #{prefix})"}"
    puts "starting hunspell (#{HUNSPELL_LANG})..."
    pipe = HunspellPipe.new(lang: HUNSPELL_LANG, personal_dict: PERSONAL_DICT)
    session_decisions = {}
    quit = false

    begin
      files.each_with_index do |path, fi|
        break if quit
        folder = File.basename(File.dirname(path))
        print "[#{fi + 1}/#{files.size}] #{folder} ... "
        $stdout.flush

        lines = File.readlines(path, chomp: true)
        changed = false
        flagged = 0

        lines.each_with_index do |line, i|
          break if quit
          next if line.strip.empty?
          record = JSON.parse(line)
          record_changed = false

          fields.each do |field|
            break if quit
            val = record[field]
            next if val.nil? || val.empty?
            original_val = val

            loop do
              misses = pipe.check(val)
              misses.reject! { |m| %i[skip add].include?(session_decisions[m[:word]]) }

              if (auto = misses.find { |m| session_decisions[m[:word]].is_a?(String) })
                val = replace_at(val, auto[:offset], auto[:word], session_decisions[auto[:word]])
                record_changed = true
                next
              end

              miss = misses.first
              break unless miss

              if flagged.zero?
                puts
                puts "[#{path}]"
              end
              flagged += 1

              action = prompt(record[id_key], field, val, miss)
              case action.first
              when :quit
                quit = true
                break
              when :skip
                session_decisions[miss[:word]] = :skip
              when :add
                session_decisions[miss[:word]] = :add
              when :replace
                replacement = action[1]
                val = replace_at(val, miss[:offset], miss[:word], replacement)
                session_decisions[miss[:word]] = replacement
                record_changed = true
              end
            end

            record[field] = val if val != original_val
          end

          if record_changed
            lines[i] = JSON.generate(record)
            changed = true
          end
        end

        if changed
          KotUtils.atomic_write(path) do |tmp|
            File.open(tmp, "w") { |f| lines.each { |l| f.puts(l) } }
          end
          puts "wrote (#{flagged} flagged)"
        else
          puts flagged.zero? ? "clean" : "no changes (#{flagged} flagged)"
        end
      end
    ensure
      pipe.close
    end

    puts quit ? "stopped." : "done."
  end

  desc "Interactively spellcheck want/in_order_to in user_stories.jsonl files. " \
       "Pass a prefix to filter, e.g. rake 'spell:stories[TBP]' or 'spell:stories[TBP7_]'."
  task :stories, [:prefix] do |_, args|
    run_spellcheck(
      glob: "work/ba/**/*_user_stories.jsonl",
      fields: %w[want in_order_to],
      id_key: "story_id",
      prefix: args[:prefix].to_s
    )
  end

  desc "Interactively spellcheck description in roles.jsonl files. " \
       "Pass a prefix to filter, e.g. rake 'spell:roles[TBP69_]'."
  task :roles, [:prefix] do |_, args|
    run_spellcheck(
      glob: "work/ba/**/*_roles.jsonl",
      fields: %w[description],
      id_key: "role_id",
      prefix: args[:prefix].to_s
    )
  end
end
