---
description: Shared config — editable frontmatter defaults
defaults:
  project_name: my-app
  version: 0.1.0
  target_dir: ./dist
---

# Shared config

The frontmatter `defaults` section seeds the state store *before* any block runs.
When a code fence declares an `inputs` field with the same name as one of those
defaults, its editable form is pre-filled from the frontmatter value instead of
showing blank — and every block that declares that same input name shares one
live value.

This document starts with:

- `$MDJAM_PROJECT_NAME` = `my-app`
- `$MDJAM_VERSION` = `0.1.0`
- `$MDJAM_TARGET_DIR` = `./dist`

---

## Edit the shared values

`project_name` and `version` below are editable — their fields open pre-filled
with the frontmatter defaults above, not empty. Change them, then run.

```bash
# ---
# id: configure
# description: Edit the project name and version
# inputs:
#   project_name:
#     description: Name used for the build artifact
#     default: my-app
#   version:
#     description: Semantic version to stamp
#     default: 0.1.0
# ---
echo "Configured: $MDJAM_PROJECT_NAME @ $MDJAM_VERSION"
```

---

## Same field, different block

`project_name` reappears here — because it's the same state store key, this
field opens with *whatever you last saved above*, not the original frontmatter
default. `target_dir` is new but still pre-filled from frontmatter.

```bash
# ---
# id: build
# description: Build using the shared project name
# inputs:
#   project_name:
#     description: Name used for the build artifact
#     default: my-app
#   target_dir:
#     description: Where to place build output
#     default: ./dist
# ---
mkdir -p "$MDJAM_TARGET_DIR"
artifact="$MDJAM_TARGET_DIR/$MDJAM_PROJECT_NAME-$MDJAM_VERSION.tar.gz"
touch "$artifact"
echo "Built: $artifact"
```

---

## Locking a value once it's confirmed

Mark a shared field `readonly: true` in a later block to display it without
letting it be re-edited — useful once a value has been "confirmed" upstream.

```bash
# ---
# id: package
# description: Package the build, version is now locked
# inputs:
#   version:
#     description: Version stamped on this package (confirmed above)
#     readonly: true
#   project_name:
#     description: Project name (confirmed above)
#     readonly: true
# depends:
#   - build
# ---
echo "Packaging $MDJAM_PROJECT_NAME v$MDJAM_VERSION for release."
```

---

## Notes

- Frontmatter `defaults` only sets the *initial* state store value — after that,
  the state store is the single source of truth every block reads from.
- An `inputs` field's `default:` is only used when the state store has no value
  for that key yet (e.g. no frontmatter default and no block has set it).
- Editing a field in one block and running it updates the state store
  immediately, so any other block sharing that input name reflects the change
  next time you view or run it.
- Combine with `readonly: true` (see [02-variables.md](02-variables.md)) once a
  shared value shouldn't be changed anymore.
