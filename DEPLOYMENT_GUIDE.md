Section-Based JSON Retrieval Plan
1. Background

The underwriting payload was previously stored as a single large JSON column, which caused:

High query latency

Large MCP payloads

Excessive LLM token usage

The database schema has now evolved to store the payload as multiple smaller JSON columns (~13 sections).

This enables selective retrieval of only the data required for a given agent task.

2. Goal

Design an MCP server interface that:

Avoids fetching full payloads

Supports flexible agent-driven data access

Remains deterministic, safe, and production-grade

Minimizes MCP tool count and token usage

3. Core Design Principle

One MCP tool, section-based retrieval, explicit allowlist mapping.

Do not create one tool per section.

4. MCP Tool Interface
Tool Name

get_submission_sections

Inputs
Parameter	Type	Description
identifier_type	string	friendly_id | convr_id | internal_id
identifier_value	string	Identifier value
sections	list[string]	Logical section names requested by agent
Example Input
{
  "identifier_type": "friendly_id",
  "identifier_value": "SPARK-12345",
  "sections": ["d3Submission", "lossRuns"]
}

5. Identifier Resolution (Unchanged)

Resolve identifier → Underwriting.Submissions.Id

Use internal SubmissionId for all queries

This logic already exists and remains unchanged.

6. Section Allowlist Mapping (Critical)

The MCP server maintains a static mapping:

SECTION_MAP = {
  "d3Submission": "Payload_d3SubmissionJson",
  "lossRuns": "Payload_LossRunsJson",
  "insured": "Payload_InsuredJson",
  "locations": "Payload_LocationsJson",
  ...
}

Rules

Agent may only request keys in SECTION_MAP

MCP never accepts raw column names

No heuristic guessing or substring matching

7. SQL Query Strategy
Safe Query Pattern

Validate requested sections against allowlist

Build SELECT clause using mapped column names

Parameterize WHERE SubmissionId = ?

Example SQL
SELECT
  SubmissionId,
  Payload_d3SubmissionJson,
  Payload_LossRunsJson
FROM Underwriting.ConvrPayloadsNormalized
WHERE SubmissionId = ?;

8. Guardrails
Limits

Max sections per call (e.g. 5)

Optional max characters per section

Optional max total payload size

Default Behavior

If sections omitted → default to ["d3Submission"]

9. Error Handling
Scenario	Behavior
Invalid section name	Return error with allowed section list
No submission found	Return “not found”
Payload too large	Return error requesting fewer sections
10. Optional Supporting Tool (Nice-to-Have)
list_submission_sections

Returns all valid section names so the agent can discover available data.

{
  "sections": ["d3Submission", "lossRuns", "insured", ...]
}

