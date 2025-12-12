What was added & why (concise)

Single MCP tool now accepts:

identifier_type

identifier_value

Supported identifiers

friendly_id → Submissions.SparkSubmissionId

convr_id → Submissions.SubmissionSourceCode

internal_id → Submissions.Id

Identifier resolution step added

Resolve any identifier → internal Submissions.Id

Fail if not found (no guessing)

Canonical SQL query unchanged

Always runs with:

WHERE s.Id = ?


Why

Avoid tool/query duplication

Deterministic, auditable behavior

Easy to add future identifiers

LLM-safe (explicit contract)

Everything else unchanged

SQL logic

JSON extraction

Metrics

Connection pooling

Azure AD auth

