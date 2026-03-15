# Steps Table Extraction Error

**Source File:** `./raw/processes/TBP7_podat_dokumenty_sud/TBP7_podat_dokumenty_sud_tobe_opis.docx`
**Timestamp:** 2026-03-15 05:09:01 +0200

## Issue

No valid steps table could be found in the document.

## Heuristics Used

The extractor looks for a table with:
- A column containing "действия" (actions)
- A column containing "роль" (role)

## Next Steps

1. Open the source document
2. Verify the table structure
3. Ensure column headers match the expected pattern
