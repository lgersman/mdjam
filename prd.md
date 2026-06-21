# PRD: Terminal Markdown Viewer with Executable Code Fences

**Status:** Draft  
**Date:** 2026-06-10  
**Author:** lgersman

---

## 1. Overview

A terminal-based markdown viewer that renders `.md` files with full formatting and allows individual code fence blocks to be **executed inline**. The viewer goes beyond static rendering: scripts in code fences can run, produce output that appears directly beneath the fence, export named values consumed by later fences, declare typed inputs, and express dependencies on other fences. The result is a self-documenting, interactive runbook format usable from any terminal.

---

## 2. Problem Statement

Existing terminal markdown renderers (glow, mdcat, bat) are read-only. Runbooks, setup guides, and data pipelines are often written as markdown with bash code blocks that the reader must copy, paste, and run manually — in the right order, with the right environment state. There is no inline execution, no output capture, no inter-step data propagation, and no dependency management.

The goal is to collapse the gap between *documentation* and *executable script* while preserving the markdown format everyone already writes in.

---

## 3. Goals

- Render GitHub-flavored markdown beautifully in the terminal via `@opentui/core`.
- Allow code fence blocks to be executed interactively or automatically.
- Capture stdout/stderr of executed blocks and display output inline immediately below the fence.
- Enable code blocks to export named values consumed by subsequent blocks.
- Support per-block metadata (inputs, outputs, dependencies, auto-execute) via an embedded YAML front-matter comment.
- Parse document-level frontmatter for prerequisite checks before rendering.
- Provide interactive, editable input fields for block inputs that lack an upstream source.
- Display execution errors (non-zero exit code, stderr output) inline at the bottom of the failed code block.
- Display errors from frontmatter-declared bash code prominently at the top of the document before any content.
- Support document-level `setup` and `teardown` lifecycle scripts in frontmatter, executed before rendering and on viewer exit respectively.
- Run on Node.js 24 with Vite/Vitest as the build and test toolchain.

## 4. Non-Goals

- Support for languages other than `bash`/`sh` in the execution engine (v1).
- A file browser or multi-file workspace.
- Remote markdown fetching (URL support).
- Windows support (v1 targets Linux/macOS).
- A REPL or persistent shell session across blocks (each block runs in a fresh subshell that inherits exported state).

---

## 5. Target Users

| Persona | Use Case |
|---|---|
| DevOps / SRE | Interactive runbooks: deploy steps with inline output verification |
| Developer onboarding | Setup guides that self-verify tool availability and run install steps |
| Data engineer | Pipeline notebooks: fetch → transform → load with visible intermediate state |
| Security researcher | Audit playbooks with dependent enumeration steps |

---

## 6. Functional Requirements

### 6.1 Markdown Rendering

- **FR-01** Render full GitHub-Flavored Markdown: headings, paragraphs, lists, tables, blockquotes, inline code, links, bold, italic, horizontal rules.
- **FR-02** Syntax-highlight non-executable code fences using Tree-sitter (delegated to `@opentui/core`'s `CodeRenderable`).
- **FR-03** Support scrolling through long documents with keyboard navigation (`j`/`k`, `PgUp`/`PgDn`, `g`/`G`).
- **FR-04** Reload the document on file change (watch mode).

### 6.2 Document-Level Frontmatter

- **FR-05** Parse YAML frontmatter at the top of the markdown file.
- **FR-06** Recognize a `prerequisites` key listing required tools or environment variables.

```yaml
---
title: Deploy Production API
prerequisites:
  tools: [kubectl, helm, jq]
  env: [AWS_PROFILE, KUBECONFIG]
setup: |
  export API_URL=https://api.example.com
  export ENV=staging
teardown: |
  echo "Session ended. Deployed revision: $MDJAM_DEPLOY_REVISION"
  kubectl delete pod "$MDJAM_TEMP_POD" 2>/dev/null || true
---
```

- **FR-07** Before rendering, verify every declared prerequisite. If any fail, render a prominent diagnostic panel listing the unmet prerequisites and block execution of all code fences. Rendering the document text itself is still allowed.
- **FR-08** Frontmatter may also declare document-wide default values that code blocks can reference as inputs.

### 6.3 Code Fence Metadata

Code blocks declare metadata using a YAML comment block at the top of the fence body. The viewer strips these comment lines before execution.

**Syntax:**

````markdown
```bash
# ---
# id: fetch-token
# description: Retrieve API auth token
# auto: false
# inputs:
#   API_HOST:
#     description: Base URL for the API
#     default: https://api.example.com
#     readonly: false
#   ENVIRONMENT:
#     description: Target environment
#     default: staging
#     readonly: true
# outputs: [API_TOKEN, API_HOST]
# depends: []
# ---
TOKEN=$(curl -sf "$API_HOST/auth/token")
echo "::set-output name=API_TOKEN::$TOKEN"
echo "::set-output name=API_HOST::$API_HOST"
```
````

**Metadata fields:**

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | string | no | Unique identifier for referencing this block from other blocks |
| `description` | string | no | Human-readable label shown in the block header |
| `auto` | boolean | no (default: `false`) | If `true`, execute this block automatically when the document loads |
| `inputs` | map | no | Named inputs the block reads from the state store |
| `inputs.<name>.description` | string | no | Shown in the input panel above the fence |
| `inputs.<name>.default` | scalar | no | Value used when no upstream source has set the key |
| `inputs.<name>.readonly` | boolean | no (default: `false`) | If `true`, the input field is displayed but not editable by the user |
| `outputs` | string[] | no | Names of values this block will export via `::set-output` |
| `depends` | string[] | no | IDs of blocks that must be executed before this one |

- **FR-09** A fence without any metadata comment is treated as a display-only, manually-executable block with no inputs, outputs, or dependencies.
- **FR-10** Metadata parsing errors (malformed YAML) must surface as a visible warning in the block header without preventing document rendering.

### 6.4 Input Rendering and Editing

- **FR-11** For each declared input, render an input panel **above the code fence** showing the input name, description, current value, and source (default / upstream block ID / setup / user-entered).
- **FR-12** Inputs whose `readonly` flag is `false` render as interactive text fields the user can focus and edit (cursor navigation within the field, Enter to confirm).
- **FR-13** Inputs whose `readonly` flag is `true` render as read-only display rows — they can only be populated by an upstream block's `::set-output` or a document-level default.
- **FR-14** A block is **blocked** (cannot execute) if any of its declared inputs has no value (no default, no upstream output, no user entry). The execute hint is hidden and a "Missing inputs" label is shown.
- **FR-15** When an upstream block exports a value that satisfies another block's input, the downstream block's input panel updates immediately and its blocked state is re-evaluated.

### 6.5 Code Fence Execution

- **FR-16** Each executable code fence renders a status indicator and a keyboard hint for manual execution (e.g., `[Enter] Run`).
- **FR-17** When executed, the block spawns a child process (`/bin/bash -c`) with:
  - The fence body (minus metadata comment lines) as the script, with a trailing `export -p` sentinel injected to capture exported variables after execution.
  - The current state store exported as environment variables (`MDJAM_<KEY>`).
- **FR-18** Stdout and stderr are streamed and displayed in an output panel directly below the fence, rendered as plain text with ANSI color passthrough.
- **FR-19** The output panel shows a running execution indicator while the process is live.
- **FR-20** On process exit, the status indicator updates to success (exit 0) or failure (non-zero), with the exit code shown.
- **FR-21** The output panel is collapsible. Its default state is expanded after execution.
- **FR-22** Re-running a block clears its previous output and re-executes.
- **FR-23** A running block can be cancelled (`Esc` sends `SIGTERM`, then `SIGKILL` after a 3-second grace period).

### 6.6 Inter-Block Data Exchange

The export protocol mirrors GitHub Actions' `::set-output` syntax.

**Export syntax (inside a script):**

```bash
echo "::set-output name=MY_KEY::my_value"
```

- **FR-24** The viewer intercepts lines matching `::set-output name=<KEY>::<VALUE>` from a block's stdout. Intercepted lines are consumed and not shown in the output panel.
- **FR-41** In addition to `::set-output`, the viewer captures variables exported via plain `export VAR=value` inside the script. After process exit, the viewer diffs the exported environment against the pre-execution snapshot and writes new or changed variables into the state store. Variables that were already present in the environment before the block ran are ignored.
- **FR-25** Values written to the state store (via `::set-output` or `export` capture) use `<block-id>.<KEY>` as the canonical namespaced key; the bare `<KEY>` also resolves to the most recently set value of that name across all blocks. Values originating from the `setup` script use bare `<KEY>` only, with no namespace prefix.
- **FR-26** When a block is executed, all values currently in the state store are injected into its environment as `MDJAM_<KEY>` variables, giving the script access to every previously exported value.
- **FR-27** The state store is in-memory and reset when the document is reloaded or the viewer exits.
- **FR-28** The state panel (toggled with `s`) shows all current state store entries, their values, and the block ID that last set each entry.

### 6.7 Dependency Execution

- **FR-29** When a block with a `depends` list is executed, the viewer first recursively executes all listed dependency blocks (in topological order) if they have not already run successfully in the current session.
- **FR-30** If a dependency block fails (non-zero exit), execution of the dependent block is aborted and an error is shown.
- **FR-31** Circular dependency detection: if a cycle is found at document parse time, the involved blocks render a permanent error badge and cannot be executed.

### 6.8 Auto-Execute

- **FR-32** After prerequisites are verified successfully, all blocks with `auto: true` are executed in document order, respecting dependency resolution.
- **FR-33** Auto-execute can be suppressed globally with the CLI flag `--no-auto`.
- **FR-34** If an auto-executing block fails, subsequent auto-execute blocks that depend on it are skipped; non-dependent auto blocks still run.

### 6.9 Lifecycle Scripts

- **FR-35** Frontmatter may declare a `setup` bash script (multi-line string). It runs once after prerequisites pass and before any content is rendered or auto-execute blocks fire.
- **FR-36** The `setup` script populates the state store via two mechanisms: plain shell `export VAR=value` (captured via env diff after exit, same as FR-41) and the `::set-output name=KEY::VALUE` syntax. Both write into the state store using bare `<KEY>` (no namespace prefix) and are available to all code blocks as `MDJAM_<KEY>` environment variables.
- **FR-37** If `setup` exits with a non-zero code, a prominent error panel is shown at the top of the document (above all content) and all code fence execution is blocked.
- **FR-38** Frontmatter may declare a `teardown` bash script. It runs when the viewer exits normally (user presses `Ctrl+C` or the process receives `SIGTERM`).
- **FR-39** The full final state store is injected into the `teardown` script's environment as `MDJAM_*` variables, giving it access to every value produced during the session. `::set-output` lines emitted by `teardown` are silently consumed and not displayed, as no downstream consumers exist at exit time.
- **FR-40** `teardown` output is displayed in a dedicated exit panel that renders briefly before the viewer closes.

---

## 7. TUI Behavior and Navigation

### 7.1 Keyboard Map (default)

| Key | Action |
|---|---|
| `j` / `↓` | Scroll down |
| `k` / `↑` | Scroll up |
| `PgDn` / `Space` | Page down |
| `PgUp` / `b` | Page up |
| `g` | Jump to top |
| `G` | Jump to bottom |
| `Tab` / `Shift+Tab` | Focus next / previous interactive element (input field or executable block) |
| `Enter` | Execute focused block / confirm focused input value |
| `Esc` | Cancel focused input edit / cancel running block |
| `r` | Reload document |
| `s` | Toggle state store panel |
| `?` | Show / hide keyboard help |
| `Ctrl+C` | Quit |

### 7.2 Focus Model

- The TUI maintains a single focused element at a time.
- Executable code blocks and editable input fields are focusable.
- Focused blocks show a highlight border.
- Input fields show a text cursor when focused.

### 7.3 Block Status Indicators

| State | Indicator |
|---|---|
| Idle, never run | `○ Ready` |
| Blocked (missing inputs) | `✗ Blocked — missing: FOO, BAR` |
| Running | `⟳ Running…` (animated) |
| Succeeded | `✓ Done (exit 0)` |
| Failed | `✗ Failed (exit 1)` |
| Cancelled | `◌ Cancelled` |
| Dependency failed | `✗ Skipped — dep failed: <block-id>` |

---

## 8. CLI Interface

```
mdjam [options] <file.md>

Options:
  --no-auto          Suppress auto-execution of auto:true blocks
  --watch            Reload document on file change (default: enabled)
  --no-watch         Disable watch mode
  --theme <name>     Syntax theme: github-dark | github-light | dracula  [default: github-dark]
  -h, --help         Show help
  -v, --version      Print version
```

---

## 9. Technical Architecture

### 9.1 Stack

| Layer | Choice | Rationale |
|---|---|---|
| Runtime | Node.js 24 | Latest; native `--watch`, native fetch, improved perf |
| Build | Vite (library mode) | Fast dev loop, ESM output |
| Test | Vitest | Shares Vite config, native ESM, fast |
| TUI rendering | `@opentui/core` | Zig-backed terminal renderer with flex layout, markdown, streaming output |
| Markdown hook | `renderNode` / `createMarkdownCodeBlockRenderer` | Overrides `bash` fence rendering within `MarkdownRenderable` |
| Process execution | Node.js `child_process.spawn` | Streams stdout/stderr; injects environment |
| Frontmatter | `gray-matter` | Zero-dep YAML frontmatter parser |

### 9.2 Rendering Pipeline

```
File read
  │
  ▼
FrontmatterParser          (gray-matter → title, prerequisites, setup, teardown, defaults)
  │
  ▼
PrerequisiteChecker        (which/where for tools; process.env for vars)
  │
  ▼
LifecycleRunner.setup      (runs setup script; env diff + ::set-output → StateStore)
  │  on failure → SetupErrorPanel shown at top; all fence execution blocked
  │
  ▼
MarkdownRenderable         (@opentui/core)
  │  renderNode hook intercepts every token with type=code, lang=bash
  │
  ├─► MetadataParser       (strips # --- ... # --- YAML block from fence body)
  │
  └─► CodeFenceRenderable  (custom Renderable per fence)
        ├─ InputPanel      (above fence — editable or readonly rows)
        ├─ FenceBody       (syntax-highlighted fence body, read-only display)
        ├─ StatusBar       (execution state, keyboard hint)
        └─ OutputPanel     (streaming stdout/stderr, collapsible)

on viewer exit →
LifecycleRunner.teardown   (runs teardown script with full StateStore as MDJAM_* env)
  │  output → TeardownPanel rendered briefly before process exits
```

### 9.3 Execution Engine

```
ExecutionEngine
  ├─ StateStore           reactive in-memory Map<string, string>; emits change events
  ├─ DependencyResolver   topological sort; cycle detection at parse time
  ├─ LifecycleRunner      runs setup (before render) and teardown (on exit)
  │    ├─ snapshots env before execution; diffs after to capture plain exports
  │    └─ intercepts ::set-output lines → StateStore.set() (bare KEY for setup)
  └─ BlockRunner
       ├─ strips metadata comment lines from script body
       ├─ snapshots env before execution; diffs after to capture plain exports
       ├─ injects StateStore as MDJAM_* environment variables
       ├─ spawns /bin/bash -c <script>
       ├─ intercepts ::set-output lines → StateStore.set() (namespaced <block-id>.KEY)
       └─ pipes remaining stdout/stderr → OutputPanel stream
```

### 9.4 Component Tree

```
App
├─ PrerequisitePanel       (shown when any prerequisite fails)
├─ SetupErrorPanel         (shown when setup script exits non-zero; blocks all fence execution)
├─ StateSidePanel          (toggleable overlay; shows StateStore contents)
├─ ScrollableDocument
│    └─ MarkdownRenderable
│         ├─ [standard blocks: headings, paragraphs, lists, tables…]
│         └─ CodeFenceRenderable[]
│              ├─ InputPanel
│              │    └─ InputRow[]   (editable TextField | readonly DisplayRow)
│              ├─ FenceBody         (CodeRenderable with syntax highlighting)
│              ├─ StatusBar
│              └─ OutputPanel       (TextRenderable, streaming, collapsible)
└─ TeardownPanel           (rendered on exit; shows teardown script output before process ends)
```

### 9.5 State Store and Reactivity

- `StateStore` is a reactive `Map` backed by an `EventEmitter`.
- On `StateStore.set(key, value)`, all `InputPanel`s that declare that key re-evaluate their blocked state.
- Downstream components subscribe to change events and trigger opentui layout invalidation.

---

## 10. Proposed File Structure

```
mdjam/
├─ src/
│   ├─ cli.ts                  entry point, arg parsing
│   ├─ app.ts                  top-level TUI app component
│   ├─ parser/
│   │   ├─ frontmatter.ts      gray-matter wrapper + prerequisite types
│   │   ├─ metadata.ts         YAML comment block parser for code fences
│   │   └─ dependency.ts       dependency graph + cycle detection
│   ├─ engine/
│   │   ├─ StateStore.ts       reactive key-value store
│   │   ├─ BlockRunner.ts      spawn, stream, ::set-output interception, export capture
│   │   ├─ LifecycleRunner.ts  setup/teardown execution, env diff, bare-key state store writes
│   │   └─ ExecutionEngine.ts  dep resolution + orchestration
│   ├─ components/
│   │   ├─ PrerequisitePanel.ts
│   │   ├─ SetupErrorPanel.ts
│   │   ├─ TeardownPanel.ts
│   │   ├─ StateSidePanel.ts
│   │   ├─ CodeFenceRenderable.ts
│   │   ├─ InputPanel.ts
│   │   ├─ InputRow.ts
│   │   ├─ StatusBar.ts
│   │   └─ OutputPanel.ts
│   └─ theme/
│       └─ themes.ts           SyntaxStyle definitions
├─ test/
│   ├─ parser/
│   ├─ engine/
│   └─ fixtures/               sample .md files for integration tests
├─ package.json
├─ vite.config.ts
└─ vitest.config.ts
```

---

## 11. Example Document

````markdown
---
title: Deploy Staging API
prerequisites:
  tools: [kubectl, helm, jq]
  env: [AWS_PROFILE, KUBECONFIG]
---

# Deploy Staging API

## Step 1: Authenticate

```bash
# ---
# id: authenticate
# description: Log in and retrieve cluster credentials
# auto: true
# inputs:
#   CLUSTER_NAME:
#     description: Name of the target EKS cluster
#     default: staging-eu-west-1
#     readonly: false
# outputs: [AUTH_TOKEN, CLUSTER_ENDPOINT]
# ---
ENDPOINT=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.endpoint' -o text)
TOKEN=$(aws eks get-token --cluster-name "$CLUSTER_NAME" | jq -r .status.token)
echo "::set-output name=AUTH_TOKEN::$TOKEN"
echo "::set-output name=CLUSTER_ENDPOINT::$ENDPOINT"
```

## Step 2: Deploy

```bash
# ---
# id: deploy
# description: Helm upgrade/install
# depends: [authenticate]
# inputs:
#   AUTH_TOKEN:
#     description: Bearer token (from authenticate step)
#     readonly: true
#   CHART_VERSION:
#     description: Helm chart version to deploy
#     default: 1.4.2
#     readonly: false
# outputs: [DEPLOY_REVISION]
# ---
helm upgrade --install api ./charts/api \
  --set image.tag="$CHART_VERSION" \
  --kube-apiserver "$CLUSTER_ENDPOINT" \
  --kube-token "$AUTH_TOKEN"
REVISION=$(helm history api --max 1 -o json | jq -r '.[0].revision')
echo "::set-output name=DEPLOY_REVISION::$REVISION"
```
````

---

## 12. Open Questions / Deferred Decisions

| # | Question | Notes |
|---|---|---|
| OQ-1 | Should `bash` be the only supported execution language in v1, or also `sh`, `zsh`? | Recommend bash-only + shebang override (`#!/usr/bin/env python3`) as v2 escape hatch |
| OQ-2 | Should the output panel have a scrollback line limit? | Recommend 10,000 lines with a truncation notice |
| OQ-3 | Persistence of state store between viewer sessions (resume)? | Out of scope for v1 |
| OQ-4 | Should `::set-output` values be type-aware (numbers, booleans, JSON objects)? | v1: all values are strings |
| OQ-5 | Multi-file navigation or `@include` directives? | Out of scope for v1 |
| OQ-6 | Should `teardown` run even if `setup` or a block failed, or only on clean exit? | Always-run semantics are safer for cleanup; needs explicit decision |
| OQ-7 | Should `teardown` output be shown in a final panel or streamed to stderr? | A brief TUI exit panel is friendlier; stderr is simpler to implement |
| OQ-8 | `SIGKILL` prevents `teardown` from running — document as known limitation or mitigate? | Can mitigate with a wrapper that traps signals, but SIGKILL is by definition uncatchable |

---

## 13. Success Metrics

- A 5-step runbook with a full dependency chain executes end-to-end without the user leaving the terminal.
- All prerequisites checked and reported within 200 ms of viewer startup.
- Streaming output latency < 50 ms from process write to TUI display.
- Cold start (parse + render a 500-line `.md` file) < 300 ms.
