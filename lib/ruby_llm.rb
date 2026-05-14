require "ruby_llm"
require "json"
require "pathname"

RubyLLM.configure do |config|
  config.openai_use_system_role = true
  config.openai_api_base = ENV.fetch("OPENAI_API_BASE")
  config.openai_api_key = ENV.fetch("OPENAI_API_KEY")
end

MODEL = ENV["LLM_MODEL"] || "GLM-5.1" # "GLM-4.5-Air"
id = "KBP1"
file_opis = "/home/id/Work/FeatureTwin/rakequirements/work/ba/#{id}/#{id}_opis.md"
file_procs = "/home/id/Work/FeatureTwin/rakequirements/work/ba/#{id}/#{id}_processes.jsonl"

[file_opis, file_procs].each do |f|
  unless File.read(f).size > 0
    raise "[ERROR] file #{File.basename(f)} empty file"
  end
end

# system_prompt = "Ты российский бизнес-аналитик и системный аналитик. Ты эксперт с BPMN2 и имеещь глубокие знания о бизнес-процессах Российских Арбитражных судов, а также глубокие знания Российской судебной системы и законодательства."
system_prompt = %(
You are an experienced business analyst with deep knowledge of Russian Arbitration Court processes and expertise in BPMN2 diagrams. You write in fluent and correct technical Russian only, except for technical terms.
)

user_prompt = %(
You are given a description of the business process with the {id} = '#{id}' taken from a BPMN2 diagram. It is a sequence of steps for several business actors.

Focus on the "Описание процесса (актор и описание)" column to identify all participant actors in this workflow. If no such column exist, dedict participant actors (urser roles) from the text.

## TASK
Extract all unique actor roles and generate a JSON array of role objects with these fields:
- `role_id`: Formatted as "%{id}-R-XX" (where XX is zero-padded sequential numbering: 01, 02, 03...)
- `role`: The role name in Russian (singular form)
- `description`: A concise description of this role's responsibilities within this specific process in Russian

## RULES
1. **Inclusion criteria:**
   - ONLY include actors explicitly mentioned in the process steps
   - Each role must represent a human or organizational participant

2. **Exclusion criteria:**
   - DO NOT include "Система" (System) or automated actors
   - DO NOT include generic "Auto" roles

3. **Role naming:**
   - Use singular Russian nouns (e.g., "Судья" not "Судьи")
   - Transform actor mentions from the steps into proper role titles using your knowledge of Russian arbitration court and general business knowledge
   - Ensure role names are professional and appropriate for legal documentation

4. **Description requirements:**
   - Write compact, precise descriptions in Russian
   - Focus on responsibilities specific to THIS process #{id}

## EXPECTED JSON STRUCTURE
[
  {
    "role_id": "KBP1-R-01",
    "role": "Истец",
    "description": "Роль участника процесса, инициирующего исковое производство путем подачи искового заявления в суд. Обеспечивает представление доказательств, участие в судебных заседаниях и защиту своих законных интересов в процессе рассмотрения дела."
  },
  {
    "role_id": "KBP1-R-02",
    "role": "Ответчик",
    "description": "Роль участника процесса, к которому предъявлены исковые требования. Обеспечивает подготовку и подачу отзыва на иск, представление возражений и доказательств, а также защиту своих интересов в ходе судебного разбирательства."
  }
]

## CRITICAL: Handle System Role Anti-pattern

Sometimes you will encounter process steps with System role ("Система", "Автоматический модуль", etc.). This is weak domain modeling and must be corrected.

**NEVER create a System Role**, but do not lose steps associated with this role. Instead:

1. Look at the context of surrounding steps (preceding and following human roles)
2. Examine the `Входящие материалы` and `Исходящие материалы` columns for clues about actual responsibility
3. Use your knowledge of Russian arbitrage courts to infer which human role is the actual actor in such use-cases
4. Automated routing decisions, document categorization, and procedural determinations are **judicial functions** and should be assigned to **Судья**
5. Ensure all text in the JSON output uses valid UTF-8 encoding and is in Russian (except role_id which is in Latin)

## Constraints

- ONLY create Role entities for column role values explicitly mentioned in the process steps
- DO NOT create artificial specializations or theoretical organizational roles
- Each role MUST correspond to a real actor mentioned in the process workflow, but does not need to be named exactly like the actor

Output the JSON object.

)

chat = RubyLLM.chat(
  model: MODEL,
  provider: :openai,
  assume_model_exists: true
)
  .with_params(response_format: {type: "json_object"})
msg = chat
  .with_instructions(system_prompt)
  .with_thinking(effort: :low)
  .with_temperature(0.3)
  .ask(user_prompt, with: file_opis)

p JSON.parse(msg.content, symbolize_names: true)

=begin
id@lg:~/Work/FeatureTwin/rakequirements$ ruby lib/ruby_llm.rb
/home/id/.asdf/installs/ruby/3.4.7/lib/ruby/gems/3.4.0/gems/json-2.19.1/lib/json/common.rb:445: warning: JSON.generate: UTF-8 string passed as BINARY, this will raise an encoding error in json 3.0
[{role_id: "KBP1-R-01", role: "Истец", description: "Роль участника процесса, инициирующего исковое производство путем подачи искового заявления в суд. Обеспечивает представление доказательств, участие в судебных заседаниях и защиту своих законных интересов в процессе рассмотрения дела."}, {role_id: "KBP1-R-02", role: "Канцелярия", description: "Роль, отвечающая за прием и регистрацию входящих документов, валидацию регистрации, автоматическое распределение на судью и передачу дел в архив."}, {role_id: "KBP1-R-03", role: "Судья", description: "Роль судебного官员, рассматривающая вопросы о принятии исковых заявлений, проводящая судебные заседания, формирующая правовую позицию по делу, принимающая судебные акты и рассматривающая ходатайства и заявления."}, {role_id: "KBP1-R-04", role: "Ответчик", description: "Роль участника процесса, к которому предъявлены исковые требования. Обеспечивает подготовку и подачу отзыва на иск, представление возражений и доказательств, а также защиту своих интересов в ходе судебного разбирательства."}, {role_id: "KBP1-R-05", role: "Иные ЛУВД", description: "Роль иных лиц, участвующих в деле. Осуществляют ознакомление с материалами дела, подают отзывы на иск и встречные иски, а также участвуют в судебных процедурах и процессах."}, {role_id: "KBP1-R-06", role: "Помощник судьи", description: "Роль, обеспечивающая подготовку к судебным заседаниям, проведение собеседований, формирование проектов судебных актов и аудио протоколирование."}]
=end
