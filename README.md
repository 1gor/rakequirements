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
| 8 | `rake review_components` | **LLM**: DDD expert reviews stories for missing component links against the full 76-component catalog, and reports component gaps (stories whose need no component implements) | `{id}_opis.md` + `{id}_user_stories.jsonl` + `raw/data/components.jsonl` | `{id}_components_review.jsonl` |
| 8a | `rake apply_review` | Merges the missing links (not the gaps) into `_components.jsonl` and `_user_stories.jsonl`; skips reviews older than their stories | `{id}_components_review.jsonl` | updates existing files |

### Reverse pipeline (component-centric, per-component)

| # | Task | What it does | Input | Output |
|---|------|-------------|-------|--------|
| 6 | `rake projections` | **LLM**: identifies read-model projections each component must expose. Frozen for the November KOT: writes nothing unless `REBUILD_PROJECTIONS=1`, and story changes no longer make it rebuild | `{cid}_aggregates.jsonl` + all `_user_stories.jsonl` | `work/ta/{cid}/{cid}_projections.jsonl` |
| 6b | `rake info_gaps` | **LLM**, report only: lists the stories whose information need from the component none of its objects (aggregates, projections) represents; components with more than 150 stories are checked in batches | `{cid}_aggregates.jsonl` + `{cid}_projections.jsonl` + the `_user_stories.jsonl` linked to the component | `work/ta/{cid}/{cid}_info_gaps.jsonl` |
| 7 | `rake map_processes` | **LLM**: reverse-maps each component to its relevant business processes | `{cid}_aggregates.jsonl` + `raw/data/processes.jsonl` | `work/ta/{cid}/{cid}_processes.jsonl` |

### Utility tasks

| Task | What it does |
|------|-------------|
| `rake orphaned_components` | Lists components with zero user story references |
| `rake status` | Shows all `.err` files (failed builds) |
| `rake fix_mtime[ID]` | Fixes file timestamps after `git checkout` |

## Recommended execution order

Default concurrency is **4** (set via `RAKE_JOBS` env var in `Rakefile`), reserving one slot from the Z.ai 5-concurrent-request limit for management/introspection. Override with `RAKE_JOBS=N` (the Rakefile replaces any `rake -j` value).

```bash
# Full forward pipeline (stages 1-5)
rake opis_mds
rake roles                 # stages 2-3 run via dependencies
rake components            # stage 4
rake stories               # stage 5

# Quality review pass (stage 8)
rake review_components
rake apply_review          # merges findings into stages 4+5 outputs
rake check:component_gaps  # gaps of the review -> out/check_component_gaps.jsonl

# Component-centric analysis (stages 6-7)
rake map_processes         # stage 7 (reverse mapping)
rake projections           # stage 6, frozen: REBUILD_PROJECTIONS=1 to regenerate
rake info_gaps             # stage 6b, report only
rake check:info_gaps       # gaps of stage 6b -> out/check_info_gaps.jsonl
```

`apply_review` writes the stories after the components and then touches the review file, so neither `rake stories` nor `rake review_components` runs again because of it.

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
| `INFO_GAPS_MODEL` | Model for information object gaps | `PROJECTIONS_MODEL` |
| `ROLES_MAX_TOKENS`, `COMPONENTS_MAX_TOKENS`, `STORIES_MAX_TOKENS`, `REVIEW_MAX_TOKENS`, `INFO_GAPS_MAX_TOKENS` | Starting output budget of stages 3, 4, 5, 8, 6b; doubled after a reply that hits it (up to 131072) | `32000` |
| `INFO_GAPS_BATCH` | Most stories per stage 6b call | `150` |
| `REBUILD_PROJECTIONS` | `1` lets stage 6 regenerate the frozen projections | off |
| `LLM_TIMEOUT` | Minimum request timeout in seconds; each request gets at least one second per 30 budget tokens | `300` |
| `RAKE_JOBS` | Tasks running at once (Z.ai concurrent-request limit) | `4` |
| `QUIET` | Suppress progress output (`1`/`true`) | off |

All tasks support individual invocation:
```bash
rake 'stories[KBP1]'          # single process
rake 'projections[К-ПД]'      # single component
rake 'review_components[KBP20]' # single process review
```
