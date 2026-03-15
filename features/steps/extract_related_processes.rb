class Spinach::Features::ExtractRelatedProcesses < Spinach::FeatureSteps
  step 'the file exists that relates to process <procedd_id> being analysed' do
    pending 'step not implemented'
  end

  step 'the file contains (sub) process codes such as KBP<...>, TBP<...> or OBP<...> that are **different** from <procedd_id>' do
    pending 'step not implemented'
  end

  step 'work/<process_id>/<procedd_id>_opis.md will be searched for related process codes, and using this code relevant lines will be extracted from work/<process_id>/<procedd_id>_opis.md and a new files with main process <process_id> will be in the first line with its <process_id>, <name>, <description> fields, followed by lines for each of the related processes, also in <process_id>, <name>, <description> format.' do
    pending 'step not implemented'
  end
end
