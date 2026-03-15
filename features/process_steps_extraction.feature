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
  Then work/<process_id>/<process_id>_steps_error.md file will be generated.

Scenario: File does not exists, single process_id
  Given I have no file matching pattern "raw/processes/<process_id>_<ignored logn name>/*tobe*.docx"
  When I run rake task extract_steps[<process_id>]
  Then the task fails with error message that no matching "tobe" file is found.
