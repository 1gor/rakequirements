# rakequirements

Requirements extraction pipeline for the Russian Arbitration Court information system. Generates structured artifacts for the document «Комплексное описание требований на создание Системы».

## Pipeline stages

The pipeline follows a Rake **pull model**: each stage defines file rules where targets rebuild only when sources are newer. Stages are numbered to indicate dependency order.

### Forward pipeline (process-centric, per-process)

| # | Task | What it does | Input | Output |
|---|------|-------------|-------|--------|
| 1 | `rake opis_mds` | Converts BPMN process descriptions from Word to Markdown | `raw/processes/*_tobe_opis.docx` | `work/ba/{id}/{id}_opis.md` |
| 2 | `rake related_processes` | Looks up related process codes from a static dictionary | `{id}_opis.md` + `raw/data/processes.jsonl` | `{id}_processes.jsonl` |
| 3 | `rake roles` | **LLM**: extracts participant roles from the process description | `{id}_opis.md` + `raw/data/grouped_participants.json` | `{id}_roles.jsonl` |
| 4 | `rake components` | **LLM**: maps which system components are relevant to this process | `{id}_opis.md` + `raw/data/components.jsonl` | `{id}_components.jsonl` |
| 5 | `rake stories` | **LLM**: generates user stories linked to roles and components | `{id}_opis.md` + `{id}_roles.jsonl` + `{id}_components.jsonl` | `{id}_user_stories.jsonl` |

### Quality assurance pass (process-centric)

| # | Task | What it does | Input | Output |
|---|------|-------------|-------|--------|
| 8 | `rake review_components` | **LLM**: DDD expert reviews stories for missing component links against the full 76-component catalog | `{id}_opis.md` + `{id}_user_stories.jsonl` + `raw/data/components.jsonl` | `{id}_components_review.jsonl` |
| 8a | `rake apply_review` | Merges review findings into `_components.jsonl` and `_user_stories.jsonl` | `{id}_components_review.jsonl` | updates existing files |

### Reverse pipeline (component-centric, per-component)

| # | Task | What it does | Input | Output |
|---|------|-------------|-------|--------|
| 6 | `rake projections` | **LLM**: identifies read-model projections each component must expose | `{cid}_aggregates.jsonl` + all `_user_stories.jsonl` | `work/ta/{cid}/{cid}_projections.jsonl` |
| 7 | `rake map_processes` | **LLM**: reverse-maps each component to its relevant business processes | `{cid}_aggregates.jsonl` + `raw/data/processes.jsonl` | `work/ta/{cid}/{cid}_processes.jsonl` |

### Utility tasks

| Task | What it does |
|------|-------------|
| `rake orphaned_components` | Lists components with zero user story references |
| `rake status` | Shows all `.err` files (failed builds) |
| `rake fix_mtime[ID]` | Fixes file timestamps after `git checkout` |

## Recommended execution order

```bash
# Full forward pipeline (stages 1-5)
rake opis_mds
rake -j 8 roles           # stages 2-3 run via dependencies
rake -j 8 components      # stage 4
rake -j 8 stories         # stage 5

# Quality review pass (stage 8)
rake -j 8 review_components
rake apply_review          # merges findings into stages 4+5 outputs

# Component-centric analysis (stages 6-7)
rake -j 8 map_processes    # stage 7 (reverse mapping)
rake -j 8 projections      # stage 6 (uses stories; falls back to stage 7 for orphans)
```

After `apply_review`, re-running `rake stories` will regenerate user stories for any process whose component list was expanded.

## Directory structure

```
raw/
  processes/           # ~240 BPMN process folders (docx + bpmn files)
  data/
    components.jsonl   # 76 system components (with parent_id for sub-components)
    grouped_participants.json  # Participant registry (P-01..P-05)
    processes.jsonl    # Process catalogue
  prompts/             # LLM prompt templates per stage

work/
  ba/{process_id}/     # Per-process artifacts (220 processes)
  ta/{component_id}/   # Per-component artifacts (76 components)

rakelib/               # Rake task files, numbered by stage
lib/                   # Shared Ruby utilities
req/                   # Requirements specification for the output document
```

## LLM configuration

Uses a Z.ai Anthropic-compatible endpoint.

| Variable | Purpose | Default |
|----------|---------|---------|
| `Z_API_KEY` | API bearer token (required) | — |
| `ROLES_MODEL` | Model for role extraction | `claude-sonnet-4-5` |
| `COMPONENTS_MODEL` | Model for component mapping | `claude-sonnet-4-5` |
| `STORIES_MODEL` | Model for user stories | `claude-sonnet-4-5` |
| `PROJECTIONS_MODEL` | Model for projections | `claude-sonnet-4-5` |
| `COMP_PROCESSES_MODEL` | Model for reverse mapping | `claude-sonnet-4-5` |
| `REVIEW_COMPONENTS_MODEL` | Model for review pass | `claude-sonnet-4-5` |
| `QUIET` | Suppress progress output (`1`/`true`) | off |

All tasks support individual invocation:
```bash
rake 'stories[KBP1]'          # single process
rake 'projections[К-ПД]'      # single component
rake 'review_components[KBP20]' # single process review
```
