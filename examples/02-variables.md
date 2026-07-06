---
description: Variables — inputs, outputs, and state
variables:
  greeting: Hello
  target:
    description: Who to greet
    default: World
  session_id:
    description: Printed as JSON on stdout when mdjam exits
    default: local-dev
    output: true
---

# Variables

Blocks share data through a **state store**.
Outputs from one block become `$MDJAM_*` environment variables available to all later blocks.

The blocks below read and print state store values as they run.

---

## Document variables

The frontmatter `variables` section pre-populates the state store before any block runs.
Each entry can be a plain scalar (`name: value`) or a nested form with an optional
`description` alongside its `default` — the exact same shape as a code block's
`variables` block below.
This document started with:

- `$MDJAM_GREETING` = `Hello`
- `$MDJAM_TARGET` = `World`

```bash
# ---
# description: Reads the document-level variables
# ---
echo "$MDJAM_GREETING, $MDJAM_TARGET!"
```

`session_id` is additionally marked `output: true`, so quitting this document
(`Ctrl+C`) prints its final value as JSON on stdout:

```json
{"session_id":"local-dev"}
```

---

## Producing output with `::set-output`

Use `echo "::set-output name=KEY::VALUE"` to write a named value into the state store.
It becomes `$MDJAM_KEY` (uppercased) in every block that runs afterward.

```bash
# ---
# id: produce
# description: Generates a build tag and a work directory
# outputs:
#   - build_tag
#   - work_dir
# ---
BUILD_TAG="v$(date +%Y%m%d)-$(openssl rand -hex 3 2>/dev/null || echo abc123)"
WORK_DIR=$(mktemp -d)

echo "::set-output name=build_tag::$BUILD_TAG"
echo "::set-output name=work_dir::$WORK_DIR"

echo "Tag : $BUILD_TAG"
echo "Dir : $WORK_DIR"
```

## Consuming output from another block

```bash
# ---
# id: consume
# description: Reads the values produced above
# ---
echo "build_tag → $MDJAM_BUILD_TAG"
echo "work_dir  → $MDJAM_WORK_DIR"
ls -la "$MDJAM_WORK_DIR"
```

---

## Export capture

Any variable you `export` inside a block is captured automatically at exit —
no `::set-output` needed.

```bash
# ---
# id: exporter
# description: Exports variables implicitly
# ---
export APP_NAME=myservice
export APP_PORT=8080
echo "Exported APP_NAME and APP_PORT."
```

```bash
# ---
# id: read-exports
# description: Reads variables captured from the previous block
# ---
echo "APP_NAME : $MDJAM_APP_NAME"
echo "APP_PORT : $MDJAM_APP_PORT"
```

---

## Interactive inputs

Declare `variables` to show an editable form above the code.
Fill the fields, then press **Enter** to run.

```bash
# ---
# id: greet
# description: Personalised greeting
# variables:
#   name:
#     description: Your name
#     default: Alice
#   lang:
#     description: "Language: en / es / fr / de"
#     default: en
# ---
case "$MDJAM_LANG" in
  es) echo "Hola, $MDJAM_NAME!" ;;
  fr) echo "Bonjour, $MDJAM_NAME !" ;;
  de) echo "Hallo, $MDJAM_NAME!" ;;
  *)  echo "Hello, $MDJAM_NAME!" ;;
esac
```

## Read-only input

Mark a variable `readonly: true` to lock it — useful for values set by a previous block.

```bash
# ---
# id: stamp
# description: Stamps a file with the build tag
# variables:
#   build_tag:
#     description: The build tag (set by the produce block)
#     readonly: true
#   filename:
#     description: Target filename
#     default: release-notes.txt
# ---
echo "Build: $MDJAM_BUILD_TAG" > "$MDJAM_FILENAME"
echo "Date:  $(date)" >> "$MDJAM_FILENAME"
cat "$MDJAM_FILENAME"
```
