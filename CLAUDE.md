# CLAUDE.md — rakequirements project onboarding

## Project purpose

Generate a compliance document **«Комплексное описание требований на создание Системы»** (Comprehensive Requirements Description for an Arbitration Court IS). The required document structure is defined in `req/trebovaniya-k-sostavu-i-soderzhaniju.md`.

The system being described is a Russian Arbitration Court information system. All domain language is Russian. Code identifiers are Latin.

---

## Repository layout

```
raw/
  processes/         # Source BPMN process folders (~240 processes)
                     # Each folder: *_tobe_opis.docx, *_asis_opis.docx, *.bpmn
  data/
    components.jsonl         # 77 system components (bounded contexts), the authoritative list
    grouped_participants.json # Participant registry (P-01..P-05 groups)
    processes.jsonl          # Process catalogue with name/description
    participants.jsonl       # Flat participant list
  prompts/
    extract_roles.txt        # LLM prompt: extract roles from opis.md
    map_components.txt       # LLM prompt: map process to components
    extract_user_stories.txt # LLM prompt: generate user stories

work/
  ba/{id}/           # Per-process BA artifacts (220 processes fully built)
    {id}_opis.md           # docx -> markdown via markitdown
    {id}_processes.jsonl   # related process codes (from static dict)
    {id}_roles.jsonl       # extracted roles (LLM)
    {id}_components.jsonl  # mapped component IDs for this process (LLM)
    {id}_user_stories.jsonl # user stories with component links (LLM)
  ta/{component_id}/ # Per-component TA artifacts (76 components)
    {id}_aggregates.jsonl  # DDD aggregate roots, attributes, invariants, vocabulary

rakelib/
  1_opis_files.rake      # Stage 1: docx -> markdown
  2_procs_files.rake     # Stage 2: related processes lookup
  3_roles_files.rake     # Stage 3: LLM role extraction
  4_components_files.rake # Stage 4: LLM component mapping
  5_stories_files.rake   # Stage 5: LLM user story generation

lib/
  sources.rb    # PROCESS_IDS constant, find_source_docx()
  kot_utils.rb  # atomic_write and other utilities
  ruby_llm.rb   # RubyLLM config helpers

req/
  trebovaniya-k-sostavu-i-soderzhaniju.md  # Document structure spec
```

---

## Pipeline overview (Rake pull model)

Each stage defines file rules: targets only rebuild when sources are newer.

| Stage | Task | Input | Output |
|-------|------|-------|--------|
| 1 | `opis_mds` | `*_tobe_opis.docx` | `work/ba/{id}/{id}_opis.md` |
| 2 | `related_processes` | opis.md + processes.jsonl | `{id}_processes.jsonl` |
| 3 | `roles` | opis.md + extract_roles.txt + grouped_participants.json | `{id}_roles.jsonl` |
| 4 | `components` | opis.md + processes.jsonl + map_components.txt + components.jsonl | `{id}_components.jsonl` |
| 5 | `stories` | opis.md + roles.jsonl + components.jsonl + extract_user_stories.txt | `{id}_user_stories.jsonl` |
| 8 | `review_components` | opis.md + user_stories.jsonl + components.jsonl (full catalog) | `{id}_components_review.jsonl` |
| 8a | `apply_review` | components_review.jsonl | merges into `_components.jsonl` + `_user_stories.jsonl` |

**Component-centric stages** (per component, output in `work/ta/`):

| Stage | Task | Input | Output |
|-------|------|-------|--------|
| 6 | `projections` | aggregates.jsonl + all user_stories.jsonl | `work/ta/{cid}/{cid}_projections.jsonl` |
| 7 | `map_processes` | aggregates.jsonl + processes.jsonl (full catalogue) | `work/ta/{cid}/{cid}_processes.jsonl` |

See `README.md` for recommended execution order and full pipeline description.

Default parallelism = 4 (override with `rake -j 8`).

**Note**: CSV extraction tasks in rakelib are deprecated — the pipeline now feeds the full `_opis.md` document to the LLM instead of extracted CSV tables.

---

## LLM setup

- Provider: **Z.ai** Anthropic-compatible endpoint
- Auth: `Bearer` token (not `x-api-key`). Patch applied in rake files.
- API base: `https://api.z.ai/api/anthropic`
- Env var: `Z_API_KEY`
- Default model: `claude-sonnet-4-5` (overridable per stage via env)
- All LLM tasks retry up to 3 times with schema validation feedback on failure.

---

## Process naming conventions

| Prefix | Meaning |
|--------|---------|
| KBP | Ключевой бизнес-процесс (key business process) |
| TBP | Типовой бизнес-процесс (reusable/template process) |
| OBP | Обеспечивающий бизнес-процесс (supporting/operational process) |

---

## Data: participants

File: `raw/data/grouped_participants.json`

| Code | Group |
|------|-------|
| P-01.1 | Стороны по делу (Истец, Ответчик, Заявители, Должник, Кредиторы) |
| P-01.2 | Третьи лица и заинтересованные лица |
| P-02.1 | Председатель суда |
| P-02.2 | Председатель судебного состава |
| P-02.3 | Судья |
| P-02.4 | Сотрудник аппарата судьи |
| P-02.5 | Сотрудник аппарата суда |
| P-03.1 | Иной участник процесса (эксперт, свидетель, переводчик) |
| P-04.1 | Арбитражный заседатель |
| P-05.1 | Судебные примирители |
| P-05.2 | Медиаторы |

---

## Data: components

File: `raw/data/components.jsonl` — 77 entries. Fields: `ID`, `Type`, `Наименование компонента`, `Описание реализуемых функций`.

Component types: `legal`, `supporting`, `platform`, `operational`, `access`, `integration`, `core`.

TA artifacts in `work/ta/{ID}/{ID}_aggregates.jsonl` define the DDD model for each component (aggregate name, attributes, invariants, ubiquitous vocabulary).

---

## Current state and next steps

### Already complete
- All 220 processes have: opis.md, roles.jsonl, components.jsonl, user_stories.jsonl
- All 76 components have: aggregates.jsonl

### Step 1 — Information objects registry (NEXT)

The document requires a **реестр информационных объектов (объекты и справочники)** and a **матрица «Компонент/информационный объект»**. These are *projections* (read models / query results) — not the command-side aggregates, but what a user needs to *see* to perform a use case.

**Planned approach**: New rake task iterating over user stories. For each story, build a prompt containing:
- The user story (`want`, `in_order_to`, role description)
- List of participating component IDs with their full descriptions
- (Optionally) component aggregates from `work/ta/`

Ask the LLM: *"What named projections/resources from our system would a user need to see to successfully perform this use case? Return name + brief description."*

Output: per-story or per-component projection lists, then aggregate into a deduplicated registry.

### Step 2 — Word document assembly pipeline

Migrate a Python pandoc wrapper from another repo into this project. It traverses a directory of chapter `.md` files and produces an unformatted Word document.

The existing approved report (version 1) covered one main process. The stakeholder wants expansion to all processes. Strategy: preserve the existing v1 docx as a baseline; insert expanded matrices and registers (generated from the full pipeline) while keeping the narrative/architecture chapters intact.

### Step 3 — Final document assembly

Populate all matrices required by `req/trebovaniya-k-sostavu-i-soderzhaniju.md`:
- Реестр участников процессов
- Реестр ролей участников процессов
- Матрица «Участник/роль»
- Реестр пользовательских историй с компонентами
- Реестр процессов
- Матрица «Процесс/пользовательская история»
- Реестр компонентов с описанием функций
- Матрица «Компонент/участник процесса»
- **Реестр информационных объектов** (to be built — Step 1)
- **Матрица «Компонент/информационный объект»** (to be built — Step 1)
- Матрица «Пользовательская история/компонент»

---

## Key conventions

- All LLM output is in Russian except identifiers (Latin).
- JSON outputs are `.jsonl` (one JSON object per line).
- Errors are written to `{target}.err`, successful builds remove the `.err` file.
- Similarity warnings for user stories go to `{target}.warn`.
- `rake status` shows all `.err` files.
- `rake fix_mtime[ID]` fixes file timestamps after git checkout.
