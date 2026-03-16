require "ruby_llm/mcp"
require "json"

RubyLLM.configure do |config|
  config.openai_use_system_role = true
  config.openai_api_base = ENV.fetch("OPENAI_API_BASE")
  config.openai_api_key = ENV.fetch("OPENAI_API_KEY")
end

MODEL = ENV["LLM_MODEL"] || "glm-4.7"

client = RubyLLM::MCP.client(
  name: "filesystem",
  transport_type: :stdio,
  config: {
    command: "ruby",
    args: [
      "/home/id/lib/file_system_mcp/file_system_mcp.rb",
      Dir.pwd
    ]
  }
)

prompt_text = "List files in raw/data"
system = "Extract entities from the text. Output a JSON object with keys and values being strings. **ONLY JSON**"

chat = RubyLLM.chat(
  model: MODEL,
  provider: :openai,
  assume_model_exists: true
)
  .with_tools(*client.tools)
  .with_params(response_format: {type: "json_object"})

msg = chat
  .with_instructions(system)
  .ask(prompt_text)

p JSON.parse(msg.content, symbolize_names: true)
