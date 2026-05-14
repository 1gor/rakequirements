# CHANGES

Running log of data/source corrections made outside the normal pipeline. Share with analysts so they can reconcile upstream sources.

## 2026-04-23

### Source layout: `raw/processes/` now uses `asis/` and `tobe/` subfolders

Previously `*_asis_opis.docx` / `*_tobe_opis.docx` lived directly under `raw/processes/{id}_*/`. They are now organised into per-variant subfolders: `raw/processes/{id}_*/tobe/` and `raw/processes/{id}_*/asis/`.

Updated `lib/sources.rb` globs accordingly:
- `SOURCE_DOCS` → `raw/processes/*/tobe/*tobe*.{docx,doc}`
- `Sources.find_source_docx(id)` → `raw/processes/{id}_*/tobe/{id}*tobe*.{docx,doc}`

### Accept `.doc` in addition to `.docx`

Four processes ship as legacy `.doc` (OBP2, OBP31, OBP32, OBP36). Globs now match both extensions so they are picked up by the pipeline.

### Renamed OBP1 source files to the standard pattern

`OBP1_Formirovanie_sostavlenie_form_utv_stat_otchet/` used Cyrillic, URL-encoded filenames that did not match the `{id}_*tobe*` / `{id}_*asis*` convention and were silently skipped. Renamed:

- `tobe/[To+be]+ОБП1.+Формирование+и+составление+форм+утвержденной+статистической+отчетности.doc`
  → `tobe/OBP1_Formirovanie_sostavlenie_form_utv_stat_otchet_tobe_opis.doc`
- `asis/ОБП1.+Формирование+и+составление+форм+утвержденной+статистической+отчетности (2).doc`
  → `asis/OBP1_Formirovanie_sostavlenie_form_utv_stat_otchet_asis_opis.doc`

After these changes `PROCESS_IDS.size` = 231 (up from 226 with the broken glob).
