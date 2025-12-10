You are acting as a Senior Python Platform Engineer and AI Infrastructure Architect.

I have a WORKING MCP server implementation that connects to Azure SQL using ODBC, retrieves a large JSON payload by SubmissionID, optionally cleans nulls/empty arrays, and returns results to an agent.

Your task is to analyze my existing MCP server code and REFRACTOR it into a clean, production-grade service while PRESERVING all functionality.

You must:

1. Identify all existing responsibilities in my code, including:
   - MCP server initialization
   - Database connection (pyodbc)
   - Tool definitions
   - JSON cleanup logic
   - Logging
   - Environment configuration

2. Split the monolithic code into a proper modular structure like:
   - src/<service_name>/config.py       → environment variables & settings
   - src/<service_name>/logging_config.py → centralized logging
   - src/<service_name>/db.py            → database connection helpers
   - src/<service_name>/json_cleaner.py  → JSON null/empty cleanup utilities
   - src/<service_name>/tools/*.py       → MCP tool implementations
   - src/<service_name>/server.py        → MCP entrypoint & wiring
   - requirements.txt or pyproject.toml
   - .env.example
   - README.md

3. Convert all hardcoded values into environment-based configuration using:
   - AZURE_SQL_SERVER
   - AZURE_SQL_DATABASE
   - AZURE_SQL_AUTH
   - LOG_LEVEL

4. Add:
   - Proper docstrings
   - Type hints
   - Structured logging
   - Robust error handling
   - Clean JSON responses from tools

5. Preserve:
   - MCP framework compatibility (FastMCP / FastAPI-MCP / Anthropics MCP as applicable)
   - Existing tool behavior and inputs
   - SubmissionID-driven lookup
   - JSON cleaning functionality

6. Generate:
   - A production-ready folder structure
   - Refactored Python files
   - A clean README.md with:
     - What the service does
     - How to configure it
     - How to run it locally
     - How to test a tool call
   - A safe .env.example file
   - Updated requirements.txt

7. DO NOT:
   - Remove or change business logic
   - Hardcode secrets
   - Break existing MCP tool names or contracts
   - Introduce unrelated frameworks

8. The result must be:
   - Ready for containerization
   - Ready for CI/CD
   - Suitable for a stakeholder demo
   - Suitable for later promotion to production

First, analyze my existing code.
Then propose the new folder structure.
Then generate the full refactored files.

Proceed step-by-step and clearly label every file you generate.
