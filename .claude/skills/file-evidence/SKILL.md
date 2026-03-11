---
name: file-evidence
description: Upload files and reference them correctly in Mighty specs/tasks/decisions. Use when asked to attach screenshots, logs, PDFs, or other file artifacts and ensure they are represented in both rich text and graph evidence links.
---

# File Evidence

## Overview

Use this workflow when a spec/task/decision needs concrete file evidence (screenshots, exports, logs, docs).

## Workflow

### 1) Upload the file

```bash
mt file upload <path>
```

Notes:
- `mt upload <path>` is also supported.
- Capture the returned `file_id` and `ref` (`mighty-file:<file_id>`).

### 2) Reference the file in rich text

- Block embed (image/document block): `![[file <file_id>]]`
- Inline mention (within a sentence): `[[file <file_id>]]`

Use the block form for screenshots and visual evidence unless inline is explicitly preferred.

### 3) Link graph evidence

Attach artifact evidence to the relevant entity (spec/task/decision):

```bash
mt link --from <id> --rel documented_by --to-type file --to-ref mighty-file:<file_id> -d "Screenshot or supporting artifact"
```

If the file is primary implementation/test evidence, use the relation that best matches intent (`implemented_by`, `tested_by`, etc.).

### 4) Verify

- Download one file directly by id when needed:
  - `mt file download <file_id>`
- Download all files referenced by a spec:
  - `mt file download --spec <spec-id>`
- Optional output directory:
  - `mt file download --spec <spec-id> --out-dir .mighty/files`
- `mt show <id>` should surface the file reference/evidence link.
- Rich-text exports should preserve `![[file ...]]` or `[[file ...]]`.
