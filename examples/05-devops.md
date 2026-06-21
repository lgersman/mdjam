---
description: DevOps runbook — full feature demo
prerequisites:
  tools:
    - git
    - docker
  env:
    - HOME
setup: |
  RUNBOOK_DIR=$(mktemp -d)
  echo "::set-output name=runbook_dir::$RUNBOOK_DIR"
  mkdir -p "$RUNBOOK_DIR/logs" "$RUNBOOK_DIR/config"
  echo "$(date -Iseconds)" > "$RUNBOOK_DIR/session_start"
  echo "Runbook session started at $(cat $RUNBOOK_DIR/session_start)"
teardown: |
  END=$(date -Iseconds)
  START=$(cat "$MDJAM_RUNBOOK_DIR/session_start" 2>/dev/null || echo "unknown")
  echo "Session: $START → $END"
  rm -rf "$MDJAM_RUNBOOK_DIR"
  echo "Runbook session closed."
defaults:
  environment: staging
  image_name: myapp
  registry: registry.example.com
---

# Deployment Runbook

This runbook walks through a full application deployment using mdjam features:

- **Prerequisites** — verify `git` and `docker` are available
- **Setup / Teardown** — shared workspace, session logging
- **Inputs** — operator-provided values (env, image tag, registry)
- **Outputs** — propagate build artifacts between steps
- **Dependencies** — enforce step ordering
- **Auto blocks** — show context immediately on load

---

## 1. Environment overview

```bash
# ---
# auto: true
# description: Prints the current deployment context
# ---
echo "=== Deployment Context ==="
echo "Environment : $MDJAM_ENVIRONMENT"
echo "Image       : $MDJAM_IMAGE_NAME"
echo "Registry    : $MDJAM_REGISTRY"
echo "Operator    : ${USER:-unknown}"
echo "Host        : $(hostname)"
echo "Docker      : $(docker --version 2>/dev/null || echo 'not available')"
echo "Git         : $(git --version)"
echo "Session dir : $MDJAM_RUNBOOK_DIR"
```

---

## 2. Confirm deployment target

Fill in the inputs and press **Enter** to confirm before proceeding.

```bash
# ---
# id: confirm-target
# description: Operator confirms the target environment and image
# inputs:
#   environment:
#     description: "Target environment: staging / production"
#     default: staging
#   image_tag:
#     description: "Docker image tag to deploy (e.g. v1.4.2)"
#     default: latest
#   registry:
#     description: Container registry hostname
#     default: registry.example.com
# outputs:
#   - environment
#   - image_tag
#   - registry
#   - full_image
# ---
FULL_IMAGE="$MDJAM_REGISTRY/$MDJAM_IMAGE_NAME:$MDJAM_IMAGE_TAG"
echo "::set-output name=environment::$MDJAM_ENVIRONMENT"
echo "::set-output name=image_tag::$MDJAM_IMAGE_TAG"
echo "::set-output name=registry::$MDJAM_REGISTRY"
echo "::set-output name=full_image::$FULL_IMAGE"

echo "Target confirmed:"
echo "  Environment : $MDJAM_ENVIRONMENT"
echo "  Image       : $FULL_IMAGE"
```

---

## 3. Pre-flight checks

```bash
# ---
# id: preflight
# description: Validates connectivity and credentials
# depends:
#   - confirm-target
# outputs:
#   - preflight_ok
# ---
ERRORS=0

echo "=== Pre-flight Checks ==="

# Check docker daemon
if docker info &>/dev/null; then
  echo "✓ Docker daemon is running"
else
  echo "✗ Docker daemon not reachable"
  ERRORS=$((ERRORS + 1))
fi

# Check git repo
if git rev-parse --git-dir &>/dev/null; then
  echo "✓ Inside a git repository"
  export GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "detached")
  echo "  HEAD: $GIT_COMMIT"
else
  echo "✗ Not inside a git repository"
  ERRORS=$((ERRORS + 1))
fi

# Check registry reachability (ping only)
if ping -c1 -W2 "${MDJAM_REGISTRY%%/*}" &>/dev/null 2>&1; then
  echo "✓ Registry host reachable"
else
  echo "⚠ Registry host unreachable (continuing anyway)"
fi

echo "::set-output name=preflight_ok::$([ $ERRORS -eq 0 ] && echo true || echo false)"

if [ $ERRORS -gt 0 ]; then
  echo "Pre-flight failed with $ERRORS error(s)."
  exit 1
fi

echo "All pre-flight checks passed."
```

---

## 4. Build

```bash
# ---
# id: build
# description: Builds the Docker image
# depends:
#   - preflight
# outputs:
#   - image_id
#   - build_log
# ---
LOG="$MDJAM_RUNBOOK_DIR/logs/build.log"
IMAGE_ID="sha256:$(openssl rand -hex 32 2>/dev/null | head -c 12)…(simulated)"

echo "Building $MDJAM_FULL_IMAGE..."
echo "  context  : $PWD"
echo "  log file : $LOG"

{
  echo "=== Build Log ==="
  echo "image: $MDJAM_FULL_IMAGE"
  echo "time:  $(date -Iseconds)"
  echo "git:   $MDJAM_GIT_COMMIT"
} > "$LOG"

echo "::set-output name=image_id::$IMAGE_ID"
echo "::set-output name=build_log::$LOG"
echo "Image ID: $IMAGE_ID"
echo "Build log written to $LOG"
```

---

## 5. Test

```bash
# ---
# id: test
# description: Runs smoke tests against the built image
# depends:
#   - build
# outputs:
#   - test_report
# ---
REPORT="$MDJAM_RUNBOOK_DIR/logs/test-report.txt"

echo "Running smoke tests on $MDJAM_IMAGE_ID..."

# Simulated test suite
TESTS=(
  "container starts"
  "health endpoint responds"
  "configuration loads"
  "no leaked secrets in image"
)

PASSED=0
for TEST in "${TESTS[@]}"; do
  sleep 0.1   # simulate test duration
  echo "  ✓ $TEST"
  PASSED=$((PASSED + 1))
done

{
  echo "Test Report"
  echo "==========="
  echo "Image:  $MDJAM_IMAGE_ID"
  echo "Passed: $PASSED / ${#TESTS[@]}"
  echo "Date:   $(date -Iseconds)"
} > "$REPORT"

echo "::set-output name=test_report::$REPORT"
echo "$PASSED/${#TESTS[@]} tests passed."
```

---

## 6. Push to registry

```bash
# ---
# id: push
# description: Pushes the image to the registry
# depends:
#   - test
# outputs:
#   - digest
# ---
DIGEST="sha256:$(openssl rand -hex 32 2>/dev/null | head -c 16)"
echo "Pushing $MDJAM_FULL_IMAGE..."
sleep 0.3
echo "Pushed. Digest: $DIGEST"
echo "::set-output name=digest::$DIGEST"

echo "Push complete: $MDJAM_REGISTRY/$MDJAM_IMAGE_NAME@$DIGEST"
```

---

## 7. Deploy

```bash
# ---
# id: deploy
# description: Rolls out to the target environment
# depends:
#   - push
# inputs:
#   environment:
#     description: "Override target environment if needed"
#     readonly: true
# outputs:
#   - deployment_url
# ---
URL="https://$MDJAM_ENVIRONMENT.example.com"

echo "Rolling out to $MDJAM_ENVIRONMENT..."
echo "  Image  : $MDJAM_FULL_IMAGE"
echo "  Digest : $MDJAM_DIGEST"

sleep 0.5
echo "Rollout complete."
echo "::set-output name=deployment_url::$URL"
echo "Live at: $URL"
```

---

## 8. Post-deploy verification

```bash
# ---
# id: verify
# description: Verifies the deployment is healthy
# depends:
#   - deploy
# ---
echo "=== Post-Deploy Verification ==="
echo "URL    : $MDJAM_DEPLOYMENT_URL"
echo "Image  : $MDJAM_FULL_IMAGE"
echo "Digest : $MDJAM_DIGEST"
echo ""
echo "Simulating health check..."
sleep 0.2
echo "✓ Health check passed"

# Write summary to session log
{
  echo "--- Deployment Summary ---"
  echo "Environment : $MDJAM_ENVIRONMENT"
  echo "Image       : $MDJAM_FULL_IMAGE"
  echo "Digest      : $MDJAM_DIGEST"
  echo "URL         : $MDJAM_DEPLOYMENT_URL"
  echo "Verified    : $(date -Iseconds)"
} >> "$MDJAM_RUNBOOK_DIR/logs/build.log"

cat "$MDJAM_RUNBOOK_DIR/logs/build.log"
```

---

## Rollback

Run only if a deployment needs to be reverted — independent of the deploy chain.

```bash
# ---
# id: rollback
# description: Rolls back to the previous stable image
# inputs:
#   environment:
#     description: Environment to roll back
#     readonly: true
#   rollback_tag:
#     description: Tag to roll back to
#     default: stable
# ---
echo "Rolling back $MDJAM_ENVIRONMENT to :$MDJAM_ROLLBACK_TAG..."
sleep 0.3
echo "✓ Rollback complete — $MDJAM_ENVIRONMENT is now running :$MDJAM_ROLLBACK_TAG"
```
