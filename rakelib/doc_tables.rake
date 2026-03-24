# frozen_string_literal: true

require "json"
require "caracal"
require_relative "../lib/doc_helpers"

namespace :doc do
  desc "Generate all document tables"
  task all: %i[participants roles participant_role_matrix user_stories processes
               process_story_matrix components component_participant_matrix
               info_objects component_info_matrix story_component_matrix]

  # ---------------------------------------------------------------------------
  # Р1. Реестр участников процессов
  # ---------------------------------------------------------------------------
  desc "Р1. Реестр участников процессов"
  task :participants do
    DocHelpers.ensure_output_dir
    groups = JSON.parse(File.read("raw/data/grouped_participants.json"))

    Caracal::Document.save("out/tables/reestr_uchastnikov.docx") do |doc|
      doc.h3 "Реестр участников процессов"
      doc.p

      rows = [DocHelpers.header_row(["Код участника", "Группа", "Участник процесса"])]
      groups.each do |group|
        rows << DocHelpers.section_header_row(group["name"], 3)
        group["members"].each do |m|
          rows << [m["code"], group["name"], m["name"]]
        end
      end

      doc.table rows, &DocHelpers::TABLE_STYLE
    end
    puts "  wrote out/tables/reestr_uchastnikov.docx"
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

    Caracal::Document.save("out/tables/reestr_roley.docx") do |doc|
      doc.h3 "Реестр ролей участников процессов"
      doc.p

      rows = [DocHelpers.header_row(["Код роли", "Роль", "Описание"])]
      DocHelpers::PROCESS_TYPE_ORDER.each do |prefix|
        next unless grouped.key?(prefix)
        rows << DocHelpers.section_header_row(DocHelpers::PROCESS_TYPE_NAMES[prefix], 3)
        grouped[prefix].each do |role|
          rows << [role["role_id"], role["role"], role["description"]]
        end
      end

      doc.table rows, &DocHelpers::TABLE_STYLE
    end
    puts "  wrote out/tables/reestr_roley.docx"
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

    Caracal::Document.save("out/tables/matrica_uchastnik_rol.docx") do |doc|
      doc.h3 "Матрица «Участник/роль»"
      doc.p

      rows = [DocHelpers.header_row(["Код матрицы", "Код участника", "Участник процесса", "Код роли", "Роль"])]
      data.each_with_index do |d, i|
        rows << ["М1.%03d" % (i + 1), d[:p_code], d[:p_name], d[:role_id], d[:role]]
      end

      doc.table rows, &DocHelpers::TABLE_STYLE
    end
    puts "  wrote out/tables/matrica_uchastnik_rol.docx"
  end

  # ---------------------------------------------------------------------------
  # Р3. Реестр пользовательских историй
  # ---------------------------------------------------------------------------
  desc "Р3. Реестр пользовательских историй"
  task :user_stories do
    DocHelpers.ensure_output_dir
    all_stories = DocHelpers.load_all_jsonl("work/ba/**/*_user_stories.jsonl")

    sorted_pids = DocHelpers.sort_process_ids(all_stories.map(&:first).uniq)

    Caracal::Document.save("out/tables/reestr_us.docx") do |doc|
      doc.h3 "Реестр пользовательских историй с описанием компонентов"
      doc.p

      rows = [DocHelpers.header_row(["Код пользовательской истории", "Я как", "Хочу", "Чтобы", "Код компонента"])]
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
    puts "  wrote out/tables/reestr_us.docx"
  end

  # ---------------------------------------------------------------------------
  # Р4. Реестр процессов
  # ---------------------------------------------------------------------------
  desc "Р4. Реестр процессов"
  task :processes do
    DocHelpers.ensure_output_dir
    procs = DocHelpers.load_processes

    sorted = DocHelpers.sort_process_ids(procs.keys)

    Caracal::Document.save("out/tables/reestr_processov.docx") do |doc|
      doc.h3 "Реестр процессов"
      doc.p

      rows = [DocHelpers.header_row(["Код процесса", "Наименование процесса", "Тип процесса", "Краткое описание"])]
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
    puts "  wrote out/tables/reestr_processov.docx"
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

    Caracal::Document.save("out/tables/matrica_process_us.docx") do |doc|
      doc.h3 "Матрица «Процесс/пользовательская история»"
      doc.p

      rows = [DocHelpers.header_row(["Код матрицы", "Код процесса", "Наименование процесса", "Код пользовательской истории"])]
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
    puts "  wrote out/tables/matrica_process_us.docx"
  end

  # ---------------------------------------------------------------------------
  # Р6. Реестр компонентов Системы
  # ---------------------------------------------------------------------------
  desc "Р6. Реестр компонентов Системы"
  task :components do
    DocHelpers.ensure_output_dir
    comps = DocHelpers.load_components

    # Group: parents first, then children immediately after
    parents = comps.values.reject { |c| c["parent_id"] }
    children_by_parent = comps.values.select { |c| c["parent_id"] }.group_by { |c| c["parent_id"] }

    Caracal::Document.save("out/tables/reestr_komponentov.docx") do |doc|
      doc.h3 "Реестр компонентов Системы с описанием реализуемых функций"
      doc.p

      rows = [DocHelpers.header_row(["Код компонента", "Наименование компонента", "Тип", "Реализуемые функции"])]
      parents.each do |c|
        rows << [{content: c["ID"], bold: true}, {content: c["Наименование компонента"], bold: true}, c["Type"], c["Описание реализуемых функций"]]
        (children_by_parent[c["ID"]] || []).each do |child|
          rows << [child["ID"], child["Наименование компонента"], child["Type"], child["Описание реализуемых функций"]]
        end
      end

      doc.table rows, &DocHelpers::TABLE_STYLE
    end
    puts "  wrote out/tables/reestr_komponentov.docx"
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

    Caracal::Document.save("out/tables/matrica_komponent_uchastnik.docx") do |doc|
      doc.h3 "Матрица «Компонент/участник процесса»"
      doc.p

      rows = [DocHelpers.header_row(["Код матрицы", "Компонент", "Код компонента", "Участник процесса", "Код участника"])]
      data.each_with_index do |d, i|
        rows << ["М4.%03d" % (i + 1), d[:cname], d[:cid], d[:p_name], d[:p_code]]
      end

      doc.table rows, &DocHelpers::TABLE_STYLE
    end
    puts "  wrote out/tables/matrica_komponent_uchastnik.docx"
  end

  # ---------------------------------------------------------------------------
  # Р9. Реестр информационных объектов
  # ---------------------------------------------------------------------------
  desc "Р9. Реестр информационных объектов"
  task :info_objects do
    DocHelpers.ensure_output_dir
    comps = DocHelpers.load_components
    projections = DocHelpers.load_all_jsonl("work/ta/**/*_projections.jsonl")

    # Group by component ID (derived from projection_id prefix)
    by_component = Hash.new { |h, k| h[k] = [] }
    projections.each do |cid, proj|
      by_component[cid] << proj
    end

    Caracal::Document.save("out/tables/reestr_info_objektov.docx") do |doc|
      doc.h3 "Реестр информационных объектов (объекты и справочники)"
      doc.p

      rows = [DocHelpers.header_row(["Код информационного объекта", "Наименование информационного объекта", "Описание"])]
      by_component.keys.sort.each do |cid|
        cname = comps.dig(cid, "Наименование компонента") || cid
        rows << DocHelpers.section_header_row(cname, 3)
        by_component[cid].sort_by { |p| p["projection_id"] }.each do |proj|
          rows << [proj["projection_id"], proj["name"], proj["description"]]
        end
      end

      doc.table rows, &DocHelpers::TABLE_STYLE
    end
    puts "  wrote out/tables/reestr_info_objektov.docx"
  end

  # ---------------------------------------------------------------------------
  # М5. Матрица «Компонент/информационный объект»
  # ---------------------------------------------------------------------------
  desc "М5. Матрица «Компонент/информационный объект»"
  task :component_info_matrix do
    DocHelpers.ensure_output_dir
    comps = DocHelpers.load_components
    projections = DocHelpers.load_all_jsonl("work/ta/**/*_projections.jsonl")

    Caracal::Document.save("out/tables/matrica_komponent_info.docx") do |doc|
      doc.h3 "Матрица «Компонент/информационный объект»"
      doc.p

      rows = [DocHelpers.header_row(["Код матрицы", "Компонент", "Код компонента", "Информационный объект", "Код информационного объекта"])]
      sorted = projections.sort_by { |cid, proj| [cid, proj["projection_id"]] }
      sorted.each_with_index do |(cid, proj), i|
        cname = comps.dig(cid, "Наименование компонента") || cid
        rows << ["М5.%03d" % (i + 1), cname, cid, proj["name"], proj["projection_id"]]
      end

      doc.table rows, &DocHelpers::TABLE_STYLE
    end
    puts "  wrote out/tables/matrica_komponent_info.docx"
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

    Caracal::Document.save("out/tables/matrica_us_komponent.docx") do |doc|
      doc.h3 "Матрица «Пользовательская история/компонент»"
      doc.p

      rows = [DocHelpers.header_row(["Код матрицы", "Код пользовательской истории", "Компонент", "Код компонента"])]
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
    puts "  wrote out/tables/matrica_us_komponent.docx"
  end
end
