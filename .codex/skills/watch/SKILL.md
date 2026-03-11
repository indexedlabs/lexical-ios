---
name: watch
description: Use when asked to analyze, review, or describe a local video file (e.g., .mp4, .mov). Describes how to use the `mt watch` command to stream large videos to Gemini securely with server-side context caching and multi-turn thread support.
---

# Video Analysis via `mt watch`

## Overview

Use this skill when you need to analyze a local video file. Large video files cannot be processed directly in your local context or uploaded as standard attachments without hitting token and size limits. The `mt watch` command provides a dedicated workflow to securely upload the video in chunks, cache it server-side, and stream Gemini model responses.

## Workflow

### 1) Initial Analysis

To start a new analysis on a video, run `mt watch` with the file path and your prompt:

```bash
mt watch "/path/to/video.mp4" "Describe what happens in this video in detail."
```

If the prompt is long or complex, you can construct it first and pass it via a variable:
```bash
PROMPT="Look closely at the UI transitions. What color is the primary button before and after the click?"
mt watch "/path/to/video.mp4" "$PROMPT"
```

The command will output the model's text response.
*Note: For machine-readable output or extra diagnostics (like file deduplication or cache telemetry), append `--json` or `--verbose`.*

### 2) Follow-up Questions (Multi-turn)

When you run `mt watch` with the `--verbose` flag (or inspect the JSON output), you will receive a `thread_id`. You can use this `thread_id` to ask follow-up questions without re-uploading or re-processing the entire video from scratch. 

```bash
# Add --verbose to see the thread_id
mt watch "/path/to/video.mp4" "Describe the video" --verbose

# Use the returned thread_id for a follow-up:
mt watch "/path/to/video.mp4" "What was the text on the second screen?" --thread <thread_id>
```

### Tips & Constraints
- **Supported Formats:** .mp4, .mov, .webm
- **Deduplication:** The server hashes the file. If it has been uploaded recently, it skips the upload phase and jumps straight to analysis.
- **Context Limits:** If the video is extremely long, ask specific, targeted questions rather than broad "describe everything" prompts to get the best results from the model.
