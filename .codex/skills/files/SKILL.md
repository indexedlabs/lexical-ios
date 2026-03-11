---
name: files
description: Use when the user uploads files or a .zip archive (like user research or logs). Describes how to locate attached files in the sandbox, extract archives if necessary, synthesize findings, and save results back to Mighty.
---

# Attached Files & Archives

## Overview

Use this workflow when a user uploads files (like `.zip` archives, logs, or documents) and asks you to analyze their contents.
The system securely stages attached files directly into your sandbox. It does not automatically unzip archives; you must extract them yourself if needed.

## Workflow

### 1) Locate the attached files

Any files attached to the message are staged in the sandbox. You can locate them by exploring the `$MIGHTY_ATTACHMENTS_DIR` directory.

Tip: Use `ls $MIGHTY_ATTACHMENTS_DIR/files/` to see the exact filenames.

### 2) Read or Extract

If the file is a regular file (e.g., `.log`, `.csv`, `.md`), you can read it directly:
```bash
cat $MIGHTY_ATTACHMENTS_DIR/files/<filename>
```

If the file is a `.zip` archive, extract it into a local temporary directory within your sandbox:
```bash
mkdir -p /tmp/extracted_files
unzip $MIGHTY_ATTACHMENTS_DIR/files/<filename>.zip -d /tmp/extracted_files
```

### 3) Analyze the contents

Iterate over the files or extracted contents. You can use standard tools like `ls`, `cat`, `jq`, and `rg` to examine the structure and data. 
If the dataset is large, consider:
- Processing the files in chunks to avoid context limits.
- Synthesizing findings as you go.

### 4) Save synthesized results

Once you have completed the analysis and synthesized your findings, you MUST persist the results back into the Mighty graph so they are searchable in the future.

**Option A: Create a record (Preferred for structured text/learnings)**
Create a new spec, doc, or decision with your findings:
```bash
mt new doc "Research Findings: Q3 User Interviews" --description-file /path/to/your/synthesis.md
```

**Option B: Upload an artifact file (Preferred for large output files like CSVs or combined logs)**
If your output is a raw file, upload it as a new artifact:
```bash
mt file upload /path/to/your/compiled_results.csv
```
This command returns a reference (e.g., `![[file <file_id>]]`) which you can then link to a task or include in a comment.