User Query
    |
    v
Newton (Orchestrator)
    |
    |-- Identifies:
    |     - identifier_type
    |     - identifier_value
    |     - required sections (based on intent)
    |
    v
Underwriting Agent (UW)
    |
    |-- Calls MCP directly
    |     (no LLM involved yet)
    |
    v
MCP Server
    |
    |-- Fetches requested sections
    |
    v
Underwriting Agent (UW)
    |
    |-- Invokes LLM
    |-- Summarizes / reasons
    |
    v
Newton
    |
    v
Final Response


User Query
    |
    v
Newton (Orchestrator)
    |
    |-- Identifies:
    |     - identifier_type
    |     - identifier_value
    |-- Passes:
    |     - user query
    |     - task context
    |
    v
Underwriting Agent (UW)
    |
    |-- Invokes LLM
    |-- Determines intent
    |-- Decides required sections
    |
    v
MCP Server
    |
    |-- Fetches requested sections
    |
    v
Underwriting Agent (UW)
    |
    |-- Performs reasoning
    |-- Summarizes / evaluates
    |
    v
Newton
    |
    v
Final Response
