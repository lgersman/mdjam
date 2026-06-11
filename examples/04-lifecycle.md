---
title: Lifecycle — prerequisites, setup, and teardown
prerequisites:
  tools:
    - curl
    - jq
  env:
    - HOME
setup: |
  WORK_DIR=$(mktemp -d)
  echo "::set-output name=work_dir::$WORK_DIR"
  echo "Setup complete — workspace: $WORK_DIR"
teardown: |
  echo "Cleaning up $MDFENCE_WORK_DIR..."
  rm -rf "$MDFENCE_WORK_DIR"
  echo "Done."
---

# Lifecycle

mdrun supports three lifecycle hooks that fire around your blocks:

| Hook | When | Use for |
|------|------|---------|
| `prerequisites` | Before anything | Require tools / env vars |
| `setup` | Once on load | Create shared resources |
| `teardown` | On quit (`q`) | Clean up those resources |

---

## Prerequisites

This document requires:

- **Tools**: `curl`, `jq` — checked via `command -v`
- **Env**: `$HOME` — checked for existence in the environment

If any prerequisite fails, **all blocks are locked** and cannot be run.

> Try opening a document with `prerequisites.tools: [nonexistent-tool]` to see the
> lock screen.

---

## Setup

The `setup` script ran when this document loaded.
It created a temporary directory and stored its path in the state store:

```bash
# ---
# auto: true
# description: Shows that the setup workspace is available
# ---
echo "Workspace: $MDFENCE_WORK_DIR"
ls -la "$MDFENCE_WORK_DIR"
```

---

## Using the workspace

All blocks share `$MDFENCE_WORK_DIR` — created once by setup, available everywhere.

```bash
# ---
# id: fetch
# description: Downloads data into the workspace
# outputs:
#   - data_file
# ---
DATA="$MDFENCE_WORK_DIR/response.json"
curl -s "https://httpbin.org/get?hello=mdrun" -o "$DATA"
echo "::set-output name=data_file::$DATA"
echo "Saved to: $DATA"
wc -c < "$DATA"
```

```bash
# ---
# id: parse
# description: Parses the downloaded JSON with jq
# depends:
#   - fetch
# ---
echo "URL args received by httpbin:"
jq '.args' "$MDFENCE_DATA_FILE"
```

```bash
# ---
# id: summarise
# description: Writes a summary file
# depends:
#   - parse
# ---
SUMMARY="$MDFENCE_WORK_DIR/summary.txt"
{
  echo "Fetched: $MDFENCE_DATA_FILE"
  echo "Date:    $(date)"
  echo "Size:    $(wc -c < $MDFENCE_DATA_FILE) bytes"
} > "$SUMMARY"

cat "$SUMMARY"
echo "::set-output name=summary_file::$SUMMARY"
```

---

## Teardown

When you press **q** to quit, mdrun runs the `teardown` script before exiting.
In this document, teardown removes the whole `$WORK_DIR` workspace.

The teardown output appears in a panel at the bottom of the screen just before exit.

> Press **q** now — you'll see the cleanup message flash before the terminal restores.
