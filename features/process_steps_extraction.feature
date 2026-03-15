Feature: Extract Process Steps
  In order to further develop requirements
  As a Russian courts of arbitrage analyst
  I want to extract table with process steps from word docx file that describes a BPMN dieagram and save the table as a csv file in work/<process_id>/<process_id>_steps.csv file

Scenario: File exists, table exists, single process_id
  Given I have a file matching pattern "raw/processes/<process_id>_<ignored logn name>/*tobe*.docx"
  And there is a csv table in the file matched by steps table heuristics
  When I run rake task extract_steps[<process_id>]
  Then work/<process_id>/<process_id>_steps.csv file will be generated, containing

Scenario: File exists, table does not exist, single process_id
  Given I have a file matching pattern "raw/processes/<process_id>_<ignored logn name>/*tobe*.docx"
  And no csv table could be found in the file matched by steps table heuristics
  When I run rake task extract_steps[<process_id>]
  Then a source docx file will be found by pattern raw/processes/<process_id>_<ignored logn name>/*asis*.docx" and a steps file will be generated from this fileinstead. No changes in raw/ directory will be made, and Sources module patterns will still work, but the failure to find tables will override the ource file logic from *tobe* to *asis*. An empty file work/<process_id>/<process_id>_steps_from_asis.md file will also be generated if successful csv is generated. If no tables are found again, an error file is placed work/<process_id>/<process_id>_error_finding_steps_table.md and no work/<process_id>/<process_id>_steps_from_asis.md file will be placed.

Scenario: File does not exists, single process_id
  Given I have no file matching pattern "raw/processes/<process_id>_<ignored logn name>/*tobe*.docx"
  When I run rake task extract_steps[<process_id>]
  Then the task fails with error message that no matching "tobe" file is found.
