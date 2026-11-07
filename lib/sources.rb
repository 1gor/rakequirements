require "fileutils"

# Source documents of the active processes.
#
# raw/processes holds one flat folder per process. A folder is active when it
# holds a TO BE description and no TOBE_* marker. The markers come from the
# analysts' delivery:
#   TOBE_<id>.txt (or .docx)  the process was merged into process <id>
#   TOBE_не_требуется.txt     the process was dropped
#   ASIS_<ids>.txt            the process merges <ids>; it stays active
#   ASIS_не_требуется.txt     there is no AS IS description; it stays active
module Sources
  module_function

  PROCESSES_DIR = "raw/processes"

  def extract_id(filename)
    File.basename(filename).split("_").first
  end

  # The marker that takes a folder out of the run, or nil.
  def tobe_marker(dir)
    Dir.glob(File.join(dir, "TOBE_*")).min
  end

  # The TO BE description of a folder: <folder>_tobe_opis.docx when present,
  # otherwise the first other *tobe* document. The glob is case-sensitive, so
  # TOBE_* markers never match. KBP51 also holds an identical
  # "_tobe_opis(1).docx" copy, which this rule skips.
  def tobe_doc(dir)
    canonical = File.join(dir, "#{File.basename(dir)}_tobe_opis.docx")
    return canonical if File.exist?(canonical)

    Dir.glob(File.join(dir, "*tobe*.{docx,doc}")).min
  end

  # { process_id => TO BE document } for every active folder.
  def active_sources
    Dir.glob(File.join(PROCESSES_DIR, "*/")).sort.each_with_object({}) do |dir, sources|
      dir = dir.chomp("/")
      next if tobe_marker(dir)

      doc = tobe_doc(dir) or next
      id = extract_id(dir)
      raise "Two active folders for #{id}: #{sources[id]} and #{doc}" if sources.key?(id)

      sources[id] = doc
    end
  end

  # The mapping function Rake uses to find the source for a target
  def find_source_docx(id)
    SOURCE_BY_ID[id]
  end
end

SOURCE_BY_ID = Sources.active_sources.freeze
SOURCE_DOCS = FileList[*SOURCE_BY_ID.values]
PROCESS_IDS = SOURCE_BY_ID.keys
  .group_by { |n| n[0] }
  .values.map(&:sort)
  .flatten
  .freeze
