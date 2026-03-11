---
name: mighty
description: "Use the `mt` tool to work with this repo’s Mighty graph: run `mt prime` at session start; prefer `mt search`/`mt tree`/`mt show` before reading code; create specs/decisions/tasks and link evidence; triage `mt inbox`; and close out with `mt closeout` then `mt commit`. For full workflow + templates, run `mt prime`."
---

# Mighty (mt)

## Session start

- Run `mt prime`.
- If you need the repo prefix for citations, run `mt repo show`.

## Find context first

- Prefer `mt search <keyword>` and `mt tree` before grepping code.
- Deep dive entities with `mt show <id>`.
- Use citations in descriptions: `[Title](cite:<id_prefix>-spec-...)` / `...-dec-...` / `...-task-...` (always include link text).
- Resolve `.loro` merge conflicts using the `merge` sub-skill in `mighty/merge/`.

## Create and track work

- New spec: `mt new --title "..." --type feature --description-file -`
- New decision: `mt decision new --title "..." --rationale "..."`
- New task: `mt task new --title "..." --type task --description-file -`
- Start work: `mt claim <task-id>`
- Link evidence/relationships: `mt link ...`

## Inbox triage (when user runs `mt inbox`)

- Fix obvious typos in titles.
- Clarify titles to be concise/actionable.
- Find/link parents via `mt search`.
- Promote from triage → draft once clarified.

## Before you say “done”

- Run `mt closeout --quiet` and fix any unlinked decisions/tasks/docs it reports.
- Run `mt closeout` for the advisory changed-file prompt; link files relevant to your work (the list may include unrelated local changes).
- Record any missing decision(s), link evidence, then `mt commit`.

## File uploads and references

- Upload files with `mt file upload <path>` (or `mt upload <path>`).
- Use the returned `file_id` in rich text:
  - Block embed: `![[file <file_id>]]`
  - Inline mention: `[[file <file_id>]]`
- When graph evidence is needed, link the uploaded file artifact:
  - `mt link --from <spec-or-task-id> --rel documented_by --to-type file --to-ref mighty-file:<file_id>`
