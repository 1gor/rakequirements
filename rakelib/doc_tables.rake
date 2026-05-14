# frozen_string_literal: true

require "json"
require "caracal"
require_relative "../lib/doc_helpers"

namespace :doc do
  desc "Generate all document tables"
  task all: %i[participants roles participant_role_matrix user_stories processes
               process_story_matrix components component_participant_matrix
               info_object_projections info_object_aggregates
               component_info_matrix story_component_matrix
               component_tech_matrix]

  # ---------------------------------------------------------------------------
  # Р1. Реестр участников процессов
  # ---------------------------------------------------------------------------
  desc "Р1. Реестр участников процессов"
  task :participants do
    DocHelpers.ensure_output_dir
    groups = JSON.parse(File.read("raw/data/grouped_participants.json"))

    Caracal::Document.save("out/tables/1_reestr_uchastnikov.docx") do |doc|
      doc.h3 "Реестр участников процессов"
      doc.p

      rows = [DocHelpers.header_row(["Код участника", "Группа", "Участник процесса"], [2160, 3060, 4140])]
      groups.each do |group|
        rows << DocHelpers.section_header_row(group["name"], 3)
        group["members"].each do |m|
          rows << [m["code"], group["name"], m["name"]]
        end
      end

      doc.table rows, &DocHelpers::TABLE_STYLE
    end
    puts "  wrote out/tables/1_reestr_uchastnikov.docx"
  end

  # ---------------------------------------------------------------------------
  # Р2. Реестр ролей участников процессов
  # ---------------------------------------------------------------------------
  desc "Р2. Реестр ролей участников процессов"
  task :roles do
    DocHelpers.ensure_output_dir
    all_roles = DocHelpers.load_all_jsonl("work/ba/**/*_roles.jsonl")

    # Group by process type prefix, deduplicate by role_id
    seen = Set.new
    grouped = Hash.new { |h, k| h[k] = [] }
    DocHelpers.sort_process_ids(all_roles.map(&:first).uniq).each do |pid|
      prefix = pid[0]
      all_roles.select { |id, _| id == pid }.each do |_, role|
        next if seen.include?(role["role_id"])
        seen << role["role_id"]
        grouped[prefix] << role
      end
    end

    Caracal::Document.save("out/tables/2_reestr_roley.docx") do |doc|
      doc.h3 "Реестр ролей участников процессов"
      doc.p

      rows = [DocHelpers.header_row(["Код роли", "Роль", "Описание"], [1710, 2070, 5580])]
      DocHelpers::PROCESS_TYPE_ORDER.each do |prefix|
        next unless grouped.key?(prefix)
        rows << DocHelpers.section_header_row(DocHelpers::PROCESS_TYPE_NAMES[prefix], 3)
        grouped[prefix].each do |role|
          rows << [role["role_id"], role["role"], role["description"]]
        end
      end

      doc.table rows, &DocHelpers::TABLE_STYLE
    end
    puts "  wrote out/tables/2_reestr_roley.docx"
  end

  # ---------------------------------------------------------------------------
  # М1. Матрица «Участник/роль»
  # ---------------------------------------------------------------------------
  desc "М1. Матрица «Участник/роль»"
  task :participant_role_matrix do
    DocHelpers.ensure_output_dir
    all_roles = DocHelpers.load_all_jsonl("work/ba/**/*_roles.jsonl")

    # Unique (participant_code, role_id) pairs
    pairs = Set.new
    data = []
    all_roles.each do |_, role|
      p_code = role.dig("participant", "code")
      p_name = role.dig("participant", "name")
      key = [p_code, role["role_id"]]
      next if pairs.include?(key)
      pairs << key
      data << {p_code: p_code, p_name: p_name, role_id: role["role_id"], role: role["role"]}
    end
    data.sort_by! { |d| [d[:p_code], d[:role_id]] }

    Caracal::Document.save("out/tables/3_matrica_uchastnik_rol.docx") do |doc|
      doc.h3 "Матрица «Участник/роль»"
      doc.p

      rows = [DocHelpers.header_row(["Код матрицы", "Код участника", "Участник процесса", "Код роли", "Роль"], [990, 989, 3960, 1621, 1800])]
      data.each_with_index do |d, i|
        rows << ["М1.%03d" % (i + 1), d[:p_code], d[:p_name], d[:role_id], d[:role]]
      end

      doc.table rows, &DocHelpers::TABLE_STYLE
    end
    puts "  wrote out/tables/3_matrica_uchastnik_rol.docx"
  end

  # ---------------------------------------------------------------------------
  # Р3. Реестр пользовательских историй
  # ---------------------------------------------------------------------------
  desc "Р3. Реестр пользовательских историй"
  task :user_stories do
    DocHelpers.ensure_output_dir
    all_stories = DocHelpers.load_all_jsonl("work/ba/**/*_user_stories.jsonl")

    sorted_pids = DocHelpers.sort_process_ids(all_stories.map(&:first).uniq)

    Caracal::Document.save("out/tables/4_reestr_us.docx") do |doc|
      doc.h3 "Реестр пользовательских историй с описанием компонентов"
      doc.p

      rows = [DocHelpers.header_row(["Код пользовательской истории", "Я как", "Хочу", "Чтобы", "Код компонента"], [2085, 1530, 2250, 2340, 1154])]
      current_prefix = nil
      sorted_pids.each do |pid|
        prefix = pid[0]
        if prefix != current_prefix
          current_prefix = prefix
          rows << DocHelpers.section_header_row(DocHelpers::PROCESS_TYPE_NAMES[prefix], 5)
        end
        all_stories.select { |id, _| id == pid }.each do |_, story|
          rows << [
            story["story_id"],
            story["role"],
            story["want"],
            story["in_order_to"],
            (story["component_ids"] || []).join(", ")
          ]
        end
      end

      doc.table rows, &DocHelpers::TABLE_STYLE
    end
    puts "  wrote out/tables/4_reestr_us.docx"
  end

  # ---------------------------------------------------------------------------
  # Р4. Реестр процессов
  # ---------------------------------------------------------------------------
  desc "Р4. Реестр процессов"
  task :processes do
    DocHelpers.ensure_output_dir
    procs = DocHelpers.load_processes

    sorted = DocHelpers.sort_process_ids(procs.keys)

    Caracal::Document.save("out/tables/5_reestr_processov.docx") do |doc|
      doc.h3 "Реестр процессов"
      doc.p

      rows = [DocHelpers.header_row(["Код процесса", "Наименование процесса", "Тип процесса", "Краткое описание"], [1530, 2160, 1980, 3690])]
      current_prefix = nil
      sorted.each do |pid|
        prefix = pid[0]
        if prefix != current_prefix
          current_prefix = prefix
          rows << DocHelpers.section_header_row(DocHelpers::PROCESS_TYPE_NAMES[prefix], 4)
        end
        p = procs[pid]
        rows << [pid, p["name"], DocHelpers::PROCESS_TYPE_FULL[prefix], p["description"]]
      end

      doc.table rows, &DocHelpers::TABLE_STYLE
    end
    puts "  wrote out/tables/5_reestr_processov.docx"
  end

  # ---------------------------------------------------------------------------
  # М2. Матрица «Процесс/пользовательская история»
  # ---------------------------------------------------------------------------
  desc "М2. Матрица «Процесс/пользовательская история»"
  task :process_story_matrix do
    DocHelpers.ensure_output_dir
    all_stories = DocHelpers.load_all_jsonl("work/ba/**/*_user_stories.jsonl")
    procs = DocHelpers.load_processes

    sorted_pids = DocHelpers.sort_process_ids(all_stories.map(&:first).uniq)

    Caracal::Document.save("out/tables/6_matrica_process_us.docx") do |doc|
      doc.h3 "Матрица «Процесс/пользовательская история»"
      doc.p

      rows = [DocHelpers.header_row(["Код матрицы", "Код процесса", "Наименование процесса", "Код пользовательской истории"], [1725, 1620, 3510, 2505])]
      seq = 0
      sorted_pids.each do |pid|
        pname = procs.dig(pid, "name") || pid
        all_stories.select { |id, _| id == pid }.each do |_, story|
          seq += 1
          rows << ["М2.%03d" % seq, pid, pname, story["story_id"]]
        end
      end

      doc.table rows, &DocHelpers::TABLE_STYLE
    end
    puts "  wrote out/tables/6_matrica_process_us.docx"
  end

  # ---------------------------------------------------------------------------
  # Р6. Реестр компонентов Системы
  # ---------------------------------------------------------------------------
  desc "Р6. Реестр компонентов Системы"
  task :components do
    DocHelpers.ensure_output_dir
    comps = DocHelpers.load_components

    type_ru = {
      "operational" => "операционный",
      "legal" => "судебный",
      "supporting" => "поддерживающий",
      "platform" => "платформенный"
    }
    translate = ->(t) { type_ru[t] || t }

    # Group: parents first, then children immediately after
    parents = comps.values.reject { |c| c["parent_id"] }
    children_by_parent = comps.values.select { |c| c["parent_id"] }.group_by { |c| c["parent_id"] }

    Caracal::Document.save("out/tables/7_reestr_komponentov.docx") do |doc|
      doc.h3 "Реестр компонентов Системы с описанием реализуемых функций"
      doc.p

      rows = [DocHelpers.header_row(["Код компонента", "Наименование компонента", "Тип", "Реализуемые функции"], [1620, 2340, 2070, 3330])]
      parents.each do |c|
        rows << [{content: c["ID"], bold: true}, {content: c["Наименование компонента"], bold: true}, translate.call(c["Type"]), c["Описание реализуемых функций"]]
        (children_by_parent[c["ID"]] || []).each do |child|
          rows << [child["ID"], child["Наименование компонента"], translate.call(child["Type"]), child["Описание реализуемых функций"]]
        end
      end

      doc.table rows, &DocHelpers::TABLE_STYLE
    end
    puts "  wrote out/tables/7_reestr_komponentov.docx"
  end

  # ---------------------------------------------------------------------------
  # Требования к функциям, выполняемым Системой
  # ---------------------------------------------------------------------------
  desc "Требования к функциям, выполняемым Системой"
  task :system_features do
    DocHelpers.ensure_output_dir
    comps = DocHelpers.load_components

    parents = comps.values.reject { |c| c["parent_id"] }
    children_by_parent = comps.values.select { |c| c["parent_id"] }.group_by { |c| c["parent_id"] }

    strip_name = ->(n) { n.to_s.sub(/\AКомпонент\s+/, "").gsub(/[«»"]/, "").strip }

    ordered = []
    parents.each do |c|
      ordered << c
      (children_by_parent[c["ID"]] || []).each { |child| ordered << child }
    end

    Caracal::Document.save("out/tables/13_trebovaniya_funkcii.docx") do |doc|
      doc.h3 "Требования к функциям, выполняемым Системой"
      doc.p

      rows = [DocHelpers.header_row(["№ п/п", "Наименование компонента Системы", "Функции компонента Системы"], [540, 2520, 6300])]
      ordered.each_with_index do |c, i|
        rows << [(i + 1).to_s, strip_name.call(c["Наименование компонента"]), c["Описание реализуемых функций"]]
      end

      doc.table rows, &DocHelpers::TABLE_STYLE
    end
    puts "  wrote out/tables/13_trebovaniya_funkcii.docx"
  end

  # ---------------------------------------------------------------------------
  # М4. Матрица «Компонент/участник процесса»
  # ---------------------------------------------------------------------------
  desc "М4. Матрица «Компонент/участник процесса»"
  task :component_participant_matrix do
    DocHelpers.ensure_output_dir
    comps = DocHelpers.load_components

    # For each process: load components + roles, derive (component, participant) pairs
    pairs = Set.new
    data = []

    Dir.glob("work/ba/**/*_components.jsonl").each do |cf|
      pid = File.basename(cf).split("_").first
      roles_file = cf.sub("_components.jsonl", "_roles.jsonl")
      next unless File.exist?(roles_file)

      comp_ids = File.foreach(cf).map { |l| JSON.parse(l)["component_id"] }
      participants = File.foreach(roles_file).map { |l|
        r = JSON.parse(l)
        {code: r.dig("participant", "code"), name: r.dig("participant", "name")}
      }.uniq { |p| p[:code] }

      comp_ids.each do |cid|
        participants.each do |p|
          key = [cid, p[:code]]
          next if pairs.include?(key)
          pairs << key
          cname = comps.dig(cid, "Наименование компонента") || cid
          data << {cid: cid, cname: cname, p_code: p[:code], p_name: p[:name]}
        end
      end
    end

    data.sort_by! { |d| [d[:cid], d[:p_code]] }

    Caracal::Document.save("out/tables/9_matrica_komponent_uchastnik.docx") do |doc|
      doc.h3 "Матрица «Компонент/участник процесса»"
      doc.p

      rows = [DocHelpers.header_row(["Код матрицы", "Компонент", "Код компонента", "Участник процесса", "Код участника"], [1350, 2394, 1296, 2970, 1350])]
      data.each_with_index do |d, i|
        rows << ["М4.%03d" % (i + 1), d[:cname], d[:cid], d[:p_name], d[:p_code]]
      end

      doc.table rows, &DocHelpers::TABLE_STYLE
    end
    puts "  wrote out/tables/9_matrica_komponent_uchastnik.docx"
  end

  # ---------------------------------------------------------------------------
  # Р9.1 Реестр информационных объектов (справочники)
  # ---------------------------------------------------------------------------
  desc "Р9.1 Реестр информационных объектов (справочники)"
  task :info_object_projections do
    DocHelpers.ensure_output_dir
    comps = DocHelpers.load_components
    projections = DocHelpers.load_all_jsonl("work/ta/**/*_projections.jsonl")

    # Group by component ID (derived from projection_id prefix)
    by_component = Hash.new { |h, k| h[k] = [] }
    projections.each do |cid, proj|
      by_component[cid] << proj
    end

    Caracal::Document.save("out/tables/10-2_reestr_info_objektov_spravochniki.docx") do |doc|
      doc.h3 "Реестр информационных объектов (справочники)"
      doc.p

      rows = [DocHelpers.header_row(["Код справочника", "Наименование справочника", "Описание"], [3120, 3120, 3120])]
      by_component.keys.sort.each do |cid|
        cname = comps.dig(cid, "Наименование компонента") || cid
        rows << DocHelpers.section_header_row(cname, 3)
        by_component[cid].sort_by { |p| p["projection_id"] }.each do |proj|
          rows << [proj["projection_id"], proj["name"], proj["description"]]
        end
      end

      doc.table rows, &DocHelpers::TABLE_STYLE
    end
    puts "  wrote out/tables/10-2_reestr_info_objektov_spravochniki.docx"
  end

  # ---------------------------------------------------------------------------
  # Р9.2 Реестр информационных объектов (объекты)
  # ---------------------------------------------------------------------------
  desc "Р9.2 Реестр информационных объектов (объекты)"
  task :info_object_aggregates do
    DocHelpers.ensure_output_dir
    aggregates = DocHelpers.load_all_jsonl("work/ta/**/*_aggregates.jsonl")

    Caracal::Document.save("out/tables/10-1_reestr_info_objektov_obyekty.docx") do |doc|
      doc.h3 "Реестр информационных объектов (объекты)"
      doc.p

      rows = [DocHelpers.header_row(["Код объекта", "Наименование объекта", "Описание"], [3120, 3120, 3120])]
      aggregates.sort_by { |cid, _| cid }.each do |cid, agg|
        code = "#{cid}-AG-01"
        full = agg["Name"].to_s
        latin = full[/\A([A-Za-z][A-Za-z0-9]*)/, 1]
        gloss = full[/\(([^)]+)\)\s*\z/, 1]
        name = if gloss && latin
          "#{gloss} (#{latin})"
        else
          full
        end
        attrs = agg["Attributes"] || []
        invs = agg["Invariants"] || []

        desc_proc = proc do
          p "Атрибуты"
          ul { attrs.each { |a| li a } } unless attrs.empty?
          p "Правила"
          ul { invs.each { |i| li i } } unless invs.empty?
        end

        rows << [code, name, desc_proc]
      end

      doc.table rows, &DocHelpers::TABLE_STYLE
    end
    puts "  wrote out/tables/10-1_reestr_info_objektov_obyekty.docx"
  end

  # ---------------------------------------------------------------------------
  # М5. Матрица «Компонент/информационный объект»
  # ---------------------------------------------------------------------------
  desc "М5. Матрица «Компонент/информационный объект»"
  task :component_info_matrix do
    DocHelpers.ensure_output_dir
    comps = DocHelpers.load_components
    projections = DocHelpers.load_all_jsonl("work/ta/**/*_projections.jsonl")
    aggregates = DocHelpers.load_all_jsonl("work/ta/**/*_aggregates.jsonl")

    entries = []
    aggregates.each do |cid, agg|
      full = agg["Name"].to_s
      latin = full[/\A([A-Za-z][A-Za-z0-9]*)/, 1]
      gloss = full[/\(([^)]+)\)\s*\z/, 1]
      name = (gloss && latin) ? "#{gloss} (#{latin})" : full
      entries << [cid, "#{cid}-AG-01", name]
    end
    projections.each do |cid, proj|
      entries << [cid, proj["projection_id"], proj["name"]]
    end
    entries.sort_by! { |cid, code, _| [cid, code] }

    Caracal::Document.save("out/tables/11_matrica_komponent_info.docx") do |doc|
      doc.h3 "Матрица «Компонент/информационный объект»"
      doc.p

      rows = [DocHelpers.header_row(["Код матрицы", "Компонент", "Код компонента", "Информационный объект", "Код информационного объекта"], [1080, 2664, 1206, 2538, 1872])]
      entries.each_with_index do |(cid, code, name), i|
        cname = comps.dig(cid, "Наименование компонента") || cid
        rows << ["М5.%03d" % (i + 1), cname, cid, name, code]
      end

      doc.table rows, &DocHelpers::TABLE_STYLE
    end
    puts "  wrote out/tables/11_matrica_komponent_info.docx"
  end

  # ---------------------------------------------------------------------------
  # М6. Матрица «Пользовательская история/компонент»
  # ---------------------------------------------------------------------------
  desc "М6. Матрица «Пользовательская история/компонент»"
  task :story_component_matrix do
    DocHelpers.ensure_output_dir
    comps = DocHelpers.load_components
    all_stories = DocHelpers.load_all_jsonl("work/ba/**/*_user_stories.jsonl")

    sorted_pids = DocHelpers.sort_process_ids(all_stories.map(&:first).uniq)

    Caracal::Document.save("out/tables/12_matrica_us_komponent.docx") do |doc|
      doc.h3 "Матрица «Пользовательская история/компонент»"
      doc.p

      rows = [DocHelpers.header_row(["Код матрицы", "Код пользовательской истории", "Компонент", "Код компонента"], [1170, 1815, 5310, 1065])]
      seq = 0
      sorted_pids.each do |pid|
        all_stories.select { |id, _| id == pid }.each do |_, story|
          (story["component_ids"] || []).each do |cid|
            seq += 1
            cname = comps.dig(cid, "Наименование компонента") || cid
            rows << ["М6.%03d" % seq, story["story_id"], cname, cid]
          end
        end
      end

      doc.table rows, &DocHelpers::TABLE_STYLE
    end
    puts "  wrote out/tables/12_matrica_us_komponent.docx"
  end

  # ---------------------------------------------------------------------------
  # Матрица «Компонент/технология»
  # ---------------------------------------------------------------------------
  desc "Матрица «Компонент/технология»"
  task :component_tech_matrix do
    DocHelpers.ensure_output_dir
    rows_data = File.foreach("work/ta/component-tech-mapping.jsonl").map { |l| JSON.parse(l) }

    Caracal::Document.save("out/tables/8_matrica_komponent_tech.docx") do |doc|
      doc.h3 "Матрица «Компонент/технология»"
      doc.p

      rows = [DocHelpers.header_row(["Код компонента", "Наименование компонента", "Технологии"], [1530, 3780, 4050])]
      rows_data.each do |r|
        rows << [r["component_id"], r["component_name"], (r["technologies"] || []).join(", ")]
      end

      doc.table rows, &DocHelpers::TABLE_STYLE
    end
    puts "  wrote out/tables/8_matrica_komponent_tech.docx"
  end
end
