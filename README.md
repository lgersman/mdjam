# mdrun

A terminal markdown viewer where bash code blocks can be executed inline. Scripts run, their output appears directly below the fence, values flow between blocks, and the whole thing stays in your terminal.

## Why Bun?

This project cannot run on Node.js. The TUI engine, `@opentui/core`, is a Zig-compiled native renderer that exposes itself via `bun:ffi` — Bun's built-in foreign function interface for calling into native shared libraries. Bun can `dlopen` a `.so`/`.dylib` and call typed C-ABI functions directly from JavaScript, with zero glue code. Node.js has no equivalent; its native extension path requires N-API `.node` addons compiled against a specific Node ABI. The two mechanisms are incompatible, so the dependency on `@opentui/core` makes Bun the only viable runtime.

## Installation

```bash
bun install
bun run build
bun link          # makes `mdrun` available globally
```

## Usage

```
mdrun [options] <file.md>
mdrun --stdin [options]

Options:
  --stdin            Read markdown from stdin instead of a file
  --no-auto          Suppress auto-execution of auto:true blocks
  --no-watch         Disable file watch / reload on change
  --theme <name>     dark | light | dracula | tokyo-night  (default: dark)
  --verbose          Show document frontmatter as a header
  --delegate         On exit, write the focused block's stdout/stderr and use its exit code
  --version          Print version
  --help             Show help
```

`--stdin` is useful for piping dynamically generated markdown, e.g. from an AI agent:

```bash
ai-agent "explain this error" | mdrun --stdin
echo "# Hello\n\`\`\`bash\necho hi\n\`\`\`" | mdrun --stdin
```

Watch mode is automatically disabled when reading from stdin.

## Keyboard map

| Key | Action |
|---|---|
| `j` / `↓` | Scroll down |
| `k` / `↑` | Scroll up |
| `Space` / `PgDn` | Page down |
| `b` / `PgUp` | Page up |
| `g` | Jump to top |
| `G` | Jump to bottom |
| `Tab` / `Shift+Tab` | Focus next / previous executable block |
| `Enter` | Execute focused block |
| `Esc` | Cancel running block |
| `Ctrl+Shift+C` | Copy selected text to clipboard |
| `Ctrl+Shift+V` | Paste into focused input |
| `r` | Reload document |
| `s` | Toggle state store panel |
| `?` | Show / hide keyboard help |
| `Ctrl+C` | Quit (runs teardown script if declared) |

## Document format

### Frontmatter

Optional YAML frontmatter at the top of the file controls document-level behaviour.

```markdown
---
title: Deploy Staging
prerequisites:
  tools: [kubectl, helm, jq]
  env: [AWS_PROFILE, KUBECONFIG]
setup: |
  export BASE_URL=https://staging.example.com
teardown: |
  echo "Session ended"
---
```

| Field | Description |
|---|---|
| `title` | Displayed in the viewer header |
| `prerequisites.tools` | CLI tools that must be on `$PATH` before the viewer starts |
| `prerequisites.env` | Environment variables that must be set before the viewer starts |
| `setup` | Bash script that runs once after prerequisites pass, before rendering |
| `teardown` | Bash script that runs on quit (`Ctrl+C` or `SIGTERM`) |

If any prerequisite is unmet, a diagnostic panel is shown and all code fence execution is blocked. If `setup` exits non-zero, an error panel is shown at the top and execution is blocked.

### Executable code blocks

Bash fences become interactive. A plain fence with no metadata is manually executable with no inputs or outputs:

````markdown
```bash
echo "hello"
```
````

Add a YAML metadata comment block at the top of the fence body to declare inputs, outputs, dependencies, and auto-execution:

````markdown
```bash
# ---
# id: fetch-token
# description: Retrieve auth token
# auto: false
# inputs:
#   API_HOST:
#     description: Base URL
#     default: https://api.example.com
#     readonly: false
# outputs: [TOKEN]
# depends: []
# ---
TOKEN=$(curl -sf "$API_HOST/auth/token")
echo "::set-output name=TOKEN::$TOKEN"
```
````

#### Metadata fields

| Field | Type | Description |
|---|---|---|
| `id` | string | Unique name for this block, used by `depends` in other blocks |
| `description` | string | Label shown in the block header |
| `auto` | boolean | Execute automatically on document load (default: `false`) |
| `inputs` | map | Named values the block reads from the state store |
| `inputs.<name>.description` | string | Shown above the input field |
| `inputs.<name>.default` | string | Value used when no upstream block has set the key |
| `inputs.<name>.readonly` | boolean | Display only — cannot be edited, must come from upstream (default: `false`) |
| `outputs` | string[] | Keys this block will export via `::set-output` |
| `depends` | string[] | IDs of blocks that must succeed before this one runs |

### Exporting values between blocks

Two mechanisms write values into the shared state store:

**`::set-output` syntax** — intercepts the line without showing it in the output panel:

```bash
echo "::set-output name=MY_KEY::my_value"
```

**Plain `export`** — any variable exported by the script that was not already in the environment is captured automatically:

```bash
export MY_KEY=my_value
echo "MY_KEY is: $MY_KEY"
```

Downstream blocks receive every state store value as `MDFENCE_<KEY>` environment variables:

```bash
echo "MY_KEY is: $MDFENCE_MY_KEY"
```

Values written by a block with `id: my-block` are stored under both the bare key (`TOKEN`) and the namespaced key (`my-block.TOKEN`). Values written by `setup` use bare keys only.

### Block status indicators

| Indicator | Meaning |
|---|---|
| `Ready` | Never run |
| `Blocked — missing: FOO` | A required input has no value yet |
| `Running…` | Script is executing |
| `Done (exit 0)` | Succeeded |
| `Failed (exit 1)` | Exited non-zero |
| `Cancelled` | Cancelled with `Esc` |
| `Skipped — dep failed: <id>` | A dependency block failed |

## Development

```bash
bun test           # run unit tests
bun run build      # compile to dist/
bun run dev        # watch mode — rebuilds on source change
bun start -- <file.md>   # run the source directly without building
```

Requires Bun ≥ 1.3.14 (declared in `engines.bun`).
