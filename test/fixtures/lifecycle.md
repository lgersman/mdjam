---
title: Lifecycle Test
setup: |
  export SETUP_VAR=from_setup
  echo "::set-output name=API_BASE::https://api.example.com"
teardown: |
  echo "Session ended. API_BASE was: $MDFENCE_API_BASE"
---

# Lifecycle Test

Setup ran before this rendered.

## Step 1: Read setup variable

```bash
# ---
# id: use-setup
# description: Read variable from setup
# ---
echo "SETUP_VAR=$MDFENCE_SETUP_VAR"
echo "API_BASE=$MDFENCE_API_BASE"
```
