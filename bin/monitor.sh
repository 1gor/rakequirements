#!/bin/bash
# bin/monitor

# 1. Count Total (Source of Truth)
TOTAL=$(find data/Process_slug_ID -name "*tobe*.docx" | wc -l)

# 2. Count Done (Artefacts)
# We count non-empty stories as "Done"
DONE=$(find build/procs -name "*_story.json" -not -empty | wc -l)

# 3. Count Skipped (Empty files due to missing tables)
SKIPPED=$(find build/procs -name "*_story.json" -empty | wc -l)

# 4. Calculate Percentage
if [ "$TOTAL" -eq 0 ]; then PCT=0; else PCT=$(( 100 * (DONE + SKIPPED) / TOTAL )); fi

# 5. Display Dashboard
clear
echo "=== GRAYBEARD ETL MONITOR ==="
echo "Total Source Files : $TOTAL"
echo "-----------------------------"
echo "Completed (Success): $DONE"
echo "Completed (Skipped): $SKIPPED"
echo "Remaining          : $((TOTAL - DONE - SKIPPED))"
echo "-----------------------------"
echo "Progress           : ${PCT}%"
echo ""
echo "=== CURRENTLY WORKING ==="
# Shows files created/touched in the last minute in build/active
ls -1 build/active 2>/dev/null || echo "Idle"
