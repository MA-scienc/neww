

🧩 User Story: Enhance get_convr_original_data MCP Tool for Section-Based JSON Retrieval
Title

Underwriting Wickins – Enhance MCP get_convr_original_data for Section-Based Convr Payload Access

Description

The existing MCP tool get_convr_original_data retrieves a curated, high-level overview of underwriting submission data by querying Convr payloads using SQL JSON functions (OPENJSON, JSON_VALUE, JSON_QUERY).

With the introduction of a new Convr database schema where the original large JSON payload is decomposed into multiple smaller JSON columns (~13 logical sections), the MCP tool must be enhanced to support selective section-based data retrieval.

The enhanced tool will:

Continue to support the existing overview data retrieval (treated as the "overview" section).

Accept an optional list of logical sections to retrieve additional Convr JSON payload parts.

Enforce a server-side allowlist to control which sections can be queried.

Resolve submission identifiers deterministically before querying data.

Prevent over-fetching large payloads and maintain performance guarantees.

This change applies only to the MCP server and does not include agent-side intent routing or orchestration logic.

Acceptance Criteria
Identifier Handling

The tool must accept the following identifiers:

friendly_id → Underwriting.Submissions.SparkSubmissionId

convr_id → Underwriting.Submissions.SubmissionSourceCode

internal_id → Underwriting.Submissions.Id

All identifiers must be resolved internally to Underwriting.Submissions.Id before data retrieval.

If the identifier cannot be resolved, the tool must return a deterministic “not found” response.

Tool Interface

The tool name must remain get_convr_original_data.

The tool must accept an optional parameter:

sections: list[string]

If sections is not provided, the tool must default to:

["overview"]

Section Handling

The "overview" section must return the existing curated response built using SQL joins and JSON functions.

Additional sections must be retrieved from the new Convr schema where each section maps to a specific JSON column.

Section names provided by the caller must be validated against a server-side allowlist.

The MCP server must not accept raw column names or perform heuristic matching.

Query Behavior

The MCP server must dynamically construct the SQL SELECT clause based only on validated section mappings.

The WHERE clause must always filter by resolved internal SubmissionId.

SQL queries must remain fully parameterized for values.

Guardrails & Safety

The tool must enforce:

A maximum number of sections per request.

Optional payload size limits per section or per response.

If invalid or unsupported sections are requested, the tool must return a clear error listing allowed sections.

Response Structure

The response must return data grouped by section name, for example:

{
  "found": true,
  "submission_id": 123,
  "sections": {
    "overview": { ... },
    "lossRuns": { ... }
  }
}


Existing consumers relying on the overview data must not break.

Non-Goals (Explicit)

The MCP tool must not:

Return the full raw Convr JSON payload.

Generate SQL dynamically based on LLM input.

Perform agent-side intent classification or routing.

Apply underwriting business rules.

Definition of Done

get_convr_original_data supports section-based retrieval with "overview" preserved.

Identifier resolution is deterministic and validated.
