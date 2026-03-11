---
name: agent-artifacts
description: Upload local screenshot/video artifacts from agent runs and return renderable file embeds (`![[file ...]]`) plus `mighty-file:` refs for thread UI previews.
---

# Agent Artifacts

## When to use

Use this when a run produces local files (screenshots, recordings, logs) and the final response should show those artifacts directly in the Mighty message UI.

## Workflow

### 1) Verify artifact paths exist

```bash
ls -l /tmp/agent-browser-local-stack.png
```

If files are missing, state that explicitly and do not claim upload success.

### 2) Upload each artifact

```bash
mt file upload <path>
```

Capture:
- `file_id`
- `ref` (`mighty-file:<file_id>`)

### 3) Return renderable output

- Put `mighty-file:<file_id>` in `final_result.artifacts` (or equivalent artifact list).
- If referencing the file inline in text, write `mighty-file:<file_id>` (do NOT wrap it in markdown backticks).
- Include a block embed in the final message body for each media artifact:

```markdown
![[file <file_id>]]
```

Use block embeds for screenshots/videos so thread UI can render previews.

### 4) Optional evidence linking

When work is tied to a spec/task/decision, add a graph evidence edge:

```bash
mt link --from <id> --rel documented_by --to-type file --to-ref mighty-file:<file_id> -d "Run artifact"
```

### 5) Quick verification

- Confirm the file uploads resolved:
  - `mt file download <file_id> --out-dir /tmp`
- Confirm the final message includes `![[file <file_id>]]`.
