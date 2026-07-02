---
description: Lifecycle — prerequisites, setup, and teardown
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
  echo "Cleaning up $MDJAM_WORK_DIR..."
  rm -rf "$MDJAM_WORK_DIR"
  echo "Done."
---

# Lifecycle

mdjam supports three lifecycle hooks that fire around your blocks:

| Hook | When | Use for |
|------|------|---------|
| `prerequisites` | Before anything | Require tools / env vars |
| `setup` | Once on load | Create shared resources |
| `teardown` | On quit (`Ctrl+C`) | Clean up those resources |

---

## Prerequisites

This document requires:

- **Tools**: `curl`, `jq` — checked via `command -v`
- **Env**: `$HOME` — checked for existence in the environment

If any prerequisite fails, **mdjam exits immediately**, printing which tools/env vars
are missing to stderr — the viewer never opens.

> Try opening a document with `prerequisites.tools: [nonexistent-tool]` to see this.

---

## Setup

The `setup` script ran when this document loaded.
It created a temporary directory and stored its path in the state store:

```bash
# ---
# auto: true
# description: Shows that the setup workspace is available
# ---
echo "Workspace: $MDJAM_WORK_DIR"
ls -la "$MDJAM_WORK_DIR"
```

---

## Using the workspace

All blocks share `$MDJAM_WORK_DIR` — created once by setup, available everywhere.

```bash
# ---
# id: fetch
# description: Downloads data into the workspace
# outputs:
#   - data_file
# ---
DATA="$MDJAM_WORK_DIR/response.json"
curl -s "https://httpbin.org/get?hello=mdjam" -o "$DATA"
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
jq '.args' "$MDJAM_DATA_FILE"
```

```bash
# ---
# id: summarise
# description: Writes a summary file
# depends:
#   - parse
# ---
SUMMARY="$MDJAM_WORK_DIR/summary.txt"
{
  echo "Fetched: $MDJAM_DATA_FILE"
  echo "Date:    $(date)"
  echo "Size:    $(wc -c < $MDJAM_DATA_FILE) bytes"
} > "$SUMMARY"

cat "$SUMMARY"
echo "::set-output name=summary_file::$SUMMARY"
```

---

## Watch it run

Press **Enter** on the block below and look at the status bar: while a script
is executing, its badge cycles through a spinning braille animation
(`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`) instead of showing a static label.

```bash
# ---
# description: Sleeps for a few seconds so you can watch the spinner
# ---
echo "Starting a slow task..."
sleep 5
echo "Done!"
```

---

## Teardown

When you press **Ctrl+C** to quit, mdjam runs the `teardown` script before exiting.
In this document, teardown removes the whole `$WORK_DIR` workspace.

Teardown's stderr is printed to the real terminal right after mdjam exits; with
`--verbose`, its stdout is shown too. If `teardown` exits non-zero, that becomes
mdjam's own exit code.

> Press **Ctrl+C** now — you'll see the cleanup message after the terminal restores.
