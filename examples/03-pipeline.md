---
description: Pipeline — block dependencies
---

# Pipeline

Blocks can declare `depends` — a list of block IDs that must succeed first.
When you run a block, mdjam automatically runs its full dependency chain in order.

You can run any single block and the whole upstream chain executes automatically.
Try running **deploy** and watch install → build → test → deploy run in sequence.

---

## Step 1 — Install

```bash
# ---
# id: install
# description: Creates a temporary workspace
# outputs:
#   - workspace
# ---
WORKSPACE=$(mktemp -d)
echo "::set-output name=workspace::$WORKSPACE"

mkdir -p "$WORKSPACE/src" "$WORKSPACE/bin"
echo 'echo "app v1.0"' > "$WORKSPACE/src/main.sh"
chmod +x "$WORKSPACE/src/main.sh"

echo "Workspace: $WORKSPACE"
echo "Created:   src/main.sh"
```

## Step 2 — Build

Depends on `install`. If install failed this block shows **dep-failed**.

```bash
# ---
# id: build
# description: Compiles the project
# depends:
#   - install
# outputs:
#   - artifact
# ---
echo "Building from $MDJAM_WORKSPACE/src..."

# "Compile" — copy + chmod
cp "$MDJAM_WORKSPACE/src/main.sh" "$MDJAM_WORKSPACE/bin/app"
chmod +x "$MDJAM_WORKSPACE/bin/app"

echo "::set-output name=artifact::$MDJAM_WORKSPACE/bin/app"
echo "Artifact: $MDJAM_ARTIFACT"
```

## Step 3 — Test

Depends on `build`.

```bash
# ---
# id: test
# description: Runs the test suite
# depends:
#   - build
# ---
echo "Running tests..."

[ -f "$MDJAM_ARTIFACT" ]           && echo "✓ Artifact exists"   || { echo "✗ Artifact missing"; exit 1; }
[ -x "$MDJAM_ARTIFACT" ]           && echo "✓ Artifact is executable" || { echo "✗ Not executable"; exit 1; }
OUTPUT=$("$MDJAM_ARTIFACT")
[ "$OUTPUT" = "app v1.0" ]           && echo "✓ Output matches"    || { echo "✗ Wrong output: $OUTPUT"; exit 1; }

echo "All tests passed."
```

## Step 4 — Deploy

Run this block to trigger the full chain: install → build → test → deploy.

```bash
# ---
# id: deploy
# description: Deploys the artifact
# depends:
#   - test
# ---
echo "Deploying $MDJAM_ARTIFACT..."
echo "Simulating upload to registry..."
sleep 0.5
echo "✓ Deployed successfully (tag: $(basename $MDJAM_WORKSPACE))"
```

---

## Parallel branches

Dependencies form a DAG, not just a chain.
Both `lint` and `build` can run independently — only `package` needs both.

```bash
# ---
# id: lint
# description: Lints the source code
# depends:
#   - install
# ---
echo "Linting $MDJAM_WORKSPACE/src..."
grep -rn "echo" "$MDJAM_WORKSPACE/src" && echo "✓ Lint passed"
```

```bash
# ---
# id: package
# description: Packages lint + build outputs into a tarball
# depends:
#   - lint
#   - build
# outputs:
#   - tarball
# ---
TAR="$MDJAM_WORKSPACE/release.tar.gz"
tar -czf "$TAR" -C "$MDJAM_WORKSPACE" bin/
echo "::set-output name=tarball::$TAR"
echo "Packaged: $TAR ($(du -h $TAR | cut -f1))"
```

---

## Cleanup

```bash
# ---
# id: cleanup
# description: Removes the workspace
# depends:
#   - install
# ---
rm -rf "$MDJAM_WORKSPACE"
echo "Removed $MDJAM_WORKSPACE"
```
