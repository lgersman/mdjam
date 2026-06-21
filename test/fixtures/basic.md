---
title: Basic Runbook Test
prerequisites:
  tools: [bash]
---

# Basic Runbook

This is a basic test document.

## Step 1: Echo a message

```bash
# ---
# id: step1
# description: Print a greeting
# outputs: [GREETING]
# ---
echo "Hello from step 1!"
echo "::set-output name=GREETING::Hello World"
```

## Step 2: Use the output from step 1

```bash
# ---
# id: step2
# description: Use output from step 1
# depends: [step1]
# inputs:
#   GREETING:
#     description: Message from step 1
#     readonly: true
# ---
echo "Got: $MDJAM_GREETING"
```

## A plain block (no metadata)

```bash
echo "I have no metadata"
```

## A non-bash block (display only)

```python
print("I am not executable in v1")
```
