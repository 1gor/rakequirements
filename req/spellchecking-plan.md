# Spellchecking plan for LLM-generated text

## Problem
LLM-generated Russian text occasionally contains Latin code-switching (e.g. "proceedings" instead of "рассмотрение"), Chinese characters, and Russian typos. Current brute-force regex checks are limited.

## Approach
Use `hunspell` with Russian dictionary and a project-specific custom dictionary.

### Tools
- `hunspell` (OS-level, already available on Linux)
- `hunspell-ru` package for Russian dictionary
- Custom dictionary: `raw/data/custom_dictionary.dic` — one word per line, version-controlled
- Shell out to `hunspell -d ru_RU -p raw/data/custom_dictionary.dic` (no extra gem needed)

### Custom dictionary seeding
Bootstrap by running hunspell on the full corpus once and bulk-adding legitimate terms:
- Legal/court terminology (арбитражный жаргон)
- Process IDs (KBP1, TBP7, etc.)
- Component IDs (К-ПД, К-СП, etc.)
- Technical abbreviations (OCR, LLM, ASR, PDF, etc.)

### Rake task: `check:spelling`
1. Extract all Russian text fields from generated artifacts (roles, user stories, projections)
2. Pipe through hunspell with custom dictionary
3. Export misspelled words with context to JSONL (`out/check_spelling.jsonl`)

### Human review workflow
1. Run `rake check:spelling` after LLM generation
2. Review JSONL output
3. Fix actual typos in source artifacts
4. Add legitimate terms to `raw/data/custom_dictionary.dic`
5. Re-run — clean output = clean corpus

### Replaces
Current `check:latin_in_stories` and `check:latin_in_roles` tasks in `rakelib/check.rake` — the spellchecker subsumes both Latin detection and catches Russian typos as a bonus.

### Concern
Initial run will produce many false positives from legal terminology. The dictionary seeding step is essential before this becomes a practical workflow.
