Feature: Extract Related Processes
  In order to provide LLM with concise context
  As a Russian courts of arbitrage analyst
  I want to have a file for each source process named work/<process_id>/<procedd_id>_processes.json that contains <process_id>, <name>, <description> of the main process, identical to work/<process_id> in the parent directory, followed by <process_id>, <name>, <description> rows for each other process mentioned in the work/<process_id>/<procedd_id>_opis.md file.

Scenario: work/<process_id>/<procedd_id>_opis.md file exists.
  Given the file exists that relates to process <procedd_id> being analysed
  And the file contains (sub) process codes such as KBP<...>, TBP<...> or OBP<...> that are **different** from <procedd_id>
  Then work/<process_id>/<procedd_id>_opis.md will be searched for related process codes, and using this code relevant lines will be extracted from work/<process_id>/<procedd_id>_opis.md and a new files with main process <process_id> will be in the first line with its <process_id>, <name>, <description> fields, followed by lines for each of the related processes, also in <process_id>, <name>, <description> format.
