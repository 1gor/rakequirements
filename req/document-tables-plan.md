# Document Tables Plan

Reference: `req/trebovaniya-k-sostavu-i-soderzhaniju.md` (spec), `req/kot_dit_example.md` (DIT competitor example).

## Approach

- Use **caracal** gem to produce standalone `.docx` table files in `out/tables/`
- Each `doc:*` rake task reads pipeline artifacts and produces one Word document
- Tables are copy-pasted into the master document by the technical writer
- Rake file: `rakelib/doc_tables.rake`, all tasks under `doc:` namespace
- Shared helpers in `lib/doc_helpers.rb`

## Key conventions (from DIT analysis)

- **All matrices are flat** (one row per pair) — no pivot/cross-tab grids. Max 5 columns.
- **Код матрицы** — sequential counter (М1.001, М2.001...) added at generation time for matrix tables.
- **Intra-table section headers** — bold rows grouping by process type (KBP/TBP/OBP) or component.
- **We keep our scoped IDs** (KBP1-US-01, К-ПД-PR-01) rather than DIT's global sequential (Р3.001).
- **Sort order**: KBP → TBP → OBP by numeric suffix; components by type then ID.
- **Russian column headers** — no English field names in output.
- **Styling**: header row grey background + bold; single border 4 twips.

## Table Structures

### Р1. Реестр участников процессов (`doc:participants` → `reestr_uchastnikov.docx`)

| **Код участника** | **Группа** | **Участник процесса** |

Source: `raw/data/grouped_participants.json`. One row per participant. Group codes as bold intra-table section headers.

### Р2. Реестр ролей участников процессов (`doc:roles` → `reestr_roley.docx`)

| **Код роли** | **Роль** | **Описание** |

Source: all `work/ba/*/_roles.jsonl`. Deduplicate by role name. Sort KBP→TBP→OBP by numeric suffix. Intra-table section headers by process type.

### М1. Матрица «Участник/роль» (`doc:participant_role_matrix` → `matrica_uchastnik_rol.docx`)

| **Код матрицы** | **Код участника** | **Участник процесса** | **Код роли** | **Роль** |

Source: `_roles.jsonl` → `participant.code` + `role_id`. One row per unique (participant, role) pair.

### Р3. Реестр пользовательских историй (`doc:user_stories` → `reestr_us.docx`)

| **Код пользовательской истории** | **Я как** | **Хочу** | **Чтобы** | **Код компонента** |

Source: `work/ba/*/_user_stories.jsonl`. Sort KBP→TBP→OBP with section headers.

### Р4. Реестр процессов (`doc:processes` → `reestr_processov.docx`)

| **Код процесса** | **Наименование процесса** | **Тип процесса** | **Краткое описание** |

Source: `raw/data/processes.jsonl`. Type derived from prefix (KBP→Ключевой, TBP→Типовой, OBP→Обеспечивающий). Section headers per type.

### М2. Матрица «Процесс/пользовательская история» (`doc:process_story_matrix` → `matrica_process_us.docx`)

| **Код матрицы** | **Код процесса** | **Наименование процесса** | **Код пользовательской истории** |

Source: `_user_stories.jsonl` grouped by process. Story text omitted — available via story code in Р3. One row per (process, story) pair.

### Р6. Реестр компонентов Системы (`doc:components` → `reestr_komponentov.docx`)

| **Код компонента** | **Наименование компонента** | **Тип** | **Реализуемые функции** |

Source: `raw/data/components.jsonl`. Bold rows for parent components. Sub-components immediately follow parent.

### М4. Матрица «Компонент/участник процесса» (`doc:component_participant_matrix` → `matrica_komponent_uchastnik.docx`)

| **Код матрицы** | **Компонент** | **Код компонента** | **Участник процесса** | **Код участника** |

Source: join `_components.jsonl` + `_roles.jsonl` per process → unique (component, participant) pairs. Sorted by component.

### Р9. Реестр информационных объектов (`doc:info_objects` → `reestr_info_objektov.docx`)

| **Код информационного объекта** | **Наименование информационного объекта** | **Описание** |

Source: all `work/ta/*/_projections.jsonl`. Bold section headers per component.

### М5. Матрица «Компонент/информационный объект» (`doc:component_info_matrix` → `matrica_komponent_info.docx`)

| **Код матрицы** | **Компонент** | **Код компонента** | **Информационный объект** | **Код информационного объекта** |

Source: `_projections.jsonl`. One row per (component, projection) pair.

### М6. Матрица «Пользовательская история/компонент» (`doc:story_component_matrix` → `matrica_us_komponent.docx`)

| **Код матрицы** | **Код пользовательской истории** | **Компонент** | **Код компонента** |

Source: `_user_stories.jsonl`. One row per (story, component_id) pair (a story with 3 components = 3 rows). Story text omitted — available via story code in Р3. Component name from `components.jsonl`.

## Convenience

- `doc:all` — depends on all tables above
- Output directory: `out/tables/`
