---
name: actions
description: Guide for creating, configuring, and leveraging Mighty actions (action_def), specifically focusing on sandbox_command bindings and the use of setup/teardown commands to execute safe repo-local operations. Use when users ask to define actions, leverage setup_commands/teardown_commands, or understand the action execution model.
---

# Actions

## Overview

Mighty Actions (`action_def`) define typed, repeatable operations. They provide a safe surface to execute repo-local code, invoke internal tools, or run validation scripts with explicitly declared inputs and outputs. 

Actions are defined via local JSON payloads and upserted using the Mighty CLI. This ensures versioned, repeatable execution with clear schemas.

## Action Definitions

To define an action, you author a JSON file describing its identity, I/O schemas, and its execution binding. 

### Key Properties
- `action_id`: A unique string identifier.
- `name` / `description`: Human-readable labels.
- `input_schema_json`: A standard JSON Schema defining what arguments the action accepts. The action runner will write these to `${workdir}/.mighty/action_input.json`.
- `output_schema_json`: A JSON Schema defining what the action returns. The action must write its result to `${workdir}/.mighty/action_output.json`.
- `binding`: Describes how the action runs. The primary binding type for local code execution is `sandbox_command`.

### Sandbox Command Binding

The `sandbox_command` binding provisions an isolated environment where repo-local scripts can run safely. It supports specific lifecycle stages, including setup and teardown commands.

#### Binding Configuration

- `type`: Must be `"sandbox_command"`.
- `workdir` (optional): The working directory relative to the repository root.
- `command`: The primary command/script to execute (e.g., `"scripts/run_eval.sh"`).
- `args` (optional): An array of arguments to pass to the main command.
- `setup_commands` (optional): An array of shell commands executed sequentially *before* the main command. Useful for installing dependencies or preparing the environment (e.g., `["npm install", "make clean"]`). If any setup command fails, the action terminates early.
- `teardown_commands` (optional): An array of shell commands executed sequentially *after* the main command exits. Useful for cleanup (e.g., `["docker-compose down"]`). Teardown commands run even if the main command fails, but their failures do not override the main command's exit status.
- `env` (optional): Key-value pairs for environment variables.
- `config_ref` (optional): Materializes the space's config profile (proxy bounds, secrets) into the sandbox.

### Example: Defining an Action with Setup & Teardown

Here is an example `action.json` payload that leverages `setup_commands` and `teardown_commands`:

```json
{
  "action_id": "run_integration_tests",
  "name": "Run Integration Tests",
  "description": "Executes the integration test suite safely within the sandbox.",
  "input_schema_json": {
    "type": "object",
    "properties": {
      "test_suite": {
        "type": "string",
        "enum": ["api", "frontend"]
      }
    },
    "required": ["test_suite"]
  },
  "output_schema_json": {
    "type": "object",
    "properties": {
      "passed": { "type": "boolean" },
      "coverage_percent": { "type": "number" }
    },
    "required": ["passed"]
  },
  "binding": {
    "type": "sandbox_command",
    "workdir": "tests/integration",
    "setup_commands": [
      "npm ci",
      "docker-compose -f docker-compose.test.yml up -d db",
      "npm run wait-for-db"
    ],
    "command": "npm",
    "args": ["run", "test:ci"],
    "teardown_commands": [
      "docker-compose -f docker-compose.test.yml down -v"
    ]
  }
}
```

### Managing Actions

1. **Upsert the action:**
   Use the CLI to create or update the draft definition.
   ```bash
   mt action upsert --file action.json
   ```

2. **Publish the action:**
   Once validated, publish the action so it becomes immutable and available for runs.
   ```bash
   mt action publish <action_id>
   ```

3. **Run the action:**
   You can trigger it using `mt action run`, passing the inputs.
   ```bash
   mt action run <action_id> --input '{"test_suite": "api"}'
   ```

## Best Practices

- Always use `setup_commands` for dependencies rather than embedding `npm install && ./run.sh` in the main `command`. This keeps the execution phases clean and easier to debug.
- Use `teardown_commands` to ensure resources are cleaned up regardless of whether the main `command` succeeded or failed.
- Design actions to be non-interactive. The sandbox runner will not answer prompts.
- Output artifacts should be captured by writing to `${workdir}/.mighty/action_output.json`, as `stdout`/`stderr` are treated as logs rather than structured data.
