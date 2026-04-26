# frozen_string_literal: true

require "json"
require "open3"
require "set"
require "kot_utils"

namespace :spell do
  PERSONAL_DICT = "raw/data/spell_personal.dic"
  HUNSPELL_LANG = ENV.fetch("HUNSPELL_LANG", "ru_RU")
  SPELL_FIELDS = %w[want in_order_to].freeze

  # Run hunspell on a single line; returns array of {word:, offset:, suggestions:[]}
  def self.spell_misspellings(text)
    return [] if text.nil? || text.strip.empty?

    cmd = ["hunspell", "-d", HUNSPELL_LANG, "-i", "utf-8", "-a"]
    cmd += ["-p", File.expand_path(PERSONAL_DICT)] if File.exist?(PERSONAL_DICT)

    # `-a` (ispell pipe mode) — prefix with `^` so leading punctuation doesn't break parsing.
    input = "^#{text.tr("\n", " ")}\n"
    out, _err, _st = Open3.capture3(*cmd, stdin_data: input)

    misses = []
    out.each_line do |line|
      line = line.chomp
      case line
      when /\A& (\S+) \d+ (\d+): (.+)\z/
        word, offset, sugs = $1, $2.to_i, $3
        # offset in `-a` pipe mode is 1-based because of the `^` prefix; subtract 1.
        misses << {word: word, offset: offset - 1, suggestions: sugs.split(", ")}
      when /\A# (\S+) (\d+)\z/
        misses << {word: $1, offset: $2.to_i - 1, suggestions: []}
      end
    end
    misses
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

  # Prompt user; returns one of:
  #   [:replace, "new_word"]  | [:skip] | [:add] | [:quit]
  def self.prompt(story_id, field, text, miss)
    puts
    puts "  story:  #{story_id}  (#{field})"
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

  # Replace word at offset; returns [new_text, delta_in_length]
  def self.replace_at(text, offset, word, replacement)
    [text[0, offset] + replacement + text[offset + word.length..], replacement.length - word.length]
  end

  desc "Interactively spellcheck want/in_order_to in all user_stories.jsonl files"
  task :stories do
    files = Dir.glob("work/ba/**/*_user_stories.jsonl").sort
    session_decisions = {}  # word => :skip | :add | replacement
    quit = false

    files.each do |path|
      break if quit
      lines = File.readlines(path, chomp: true)
      changed = false

      lines.each_with_index do |line, i|
        break if quit
        next if line.strip.empty?
        story = JSON.parse(line)
        story_changed = false

        SPELL_FIELDS.each do |field|
          break if quit
          val = story[field]
          next if val.nil? || val.empty?
          original_val = val

          # Loop because replacements shift offsets — easiest is rescan after each edit.
          loop do
            misses = spell_misspellings(val)
            # Drop any whose word matches a session "skip" / "add" decision.
            misses.reject! { |m| session_decisions[m[:word]] == :skip || session_decisions[m[:word]] == :add }

            # Apply auto-replacements for words decided earlier this session.
            auto = misses.find { |m| session_decisions[m[:word]].is_a?(String) }
            if auto
              val, _ = replace_at(val, auto[:offset], auto[:word], session_decisions[auto[:word]])
              story_changed = true
              next
            end

            miss = misses.first
            break unless miss

            puts "\n[#{path}]"
            action = prompt(story["story_id"], field, val, miss)
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
              val, _ = replace_at(val, miss[:offset], miss[:word], replacement)
              session_decisions[miss[:word]] = replacement
              story_changed = true
            end
          end

          story[field] = val if val != original_val
        end

        if story_changed
          lines[i] = JSON.generate(story)
          changed = true
        end
      end

      if changed
        KotUtils.atomic_write(path) do |tmp|
          File.open(tmp, "w") { |f| lines.each { |l| f.puts(l) } }
        end
        puts "  wrote #{path}"
      end
    end

    puts quit ? "stopped." : "done."
  end
end
