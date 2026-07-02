# mdjam

A terminal markdown viewer where bash code blocks can be executed inline. Scripts run, their output appears directly below the fence, values flow between blocks, and the whole thing stays in your terminal.

Implemented in [Zig](https://ziglang.org) — ships as a single statically-linked binary with no runtime dependencies.

## Prerequisites

This project uses [mise](https://mise.jdx.dev) to manage the Zig version and [direnv](https://direnv.net) to activate it automatically when you enter the directory.

1. **Install mise:**
   ```bash
   curl https://mise.run | sh
   ```
   Then add the activation hook to your shell (`~/.bashrc`, `~/.zshrc`, etc.):
   ```bash
   eval "$(mise activate bash)"   # replace bash with zsh / fish as needed
   ```

2. **Install direnv:**
   ```bash
   # macOS
   brew install direnv
   # Ubuntu / Debian
   sudo apt install direnv
   ```
   Then hook it into your shell:
   ```bash
   echo 'eval "$(direnv hook bash)"' >> ~/.bashrc   # replace bash with zsh if needed
   ```

3. **Allow direnv** in the project directory:
   ```bash
   direnv allow
   ```
   mise will install Zig and ZLS at the versions declared in `.mise.toml` and activate them automatically on every subsequent `cd`.

## Installation

**Linux and macOS** — download and install the prebuilt binary:

```bash
curl -sSL https://raw.githubusercontent.com/lgersman/mdjam/main/install.sh | sh
```

Installs to `~/.local/bin` by default. Override with `INSTALL_DIR`:

```bash
INSTALL_DIR=/usr/local/bin curl -sSL https://raw.githubusercontent.com/lgersman/mdjam/main/install.sh | sh
```

Pin a specific version with `VERSION`:

```bash
VERSION=0.2.0 curl -sSL https://raw.githubusercontent.com/lgersman/mdjam/main/install.sh | sh
```

**Windows** — use [WSL](https://learn.microsoft.com/en-us/windows/wsl/install) and run the Linux install command above.

**Build from source** (requires [Zig](https://ziglang.org) ≥ 0.16.0):

```bash
zig build -Doptimize=ReleaseSafe
# binary is at zig-out/bin/mdjam
```

## Usage

```
mdjam [options] <file.md>
mdjam --stdin [options]

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
ai-agent "explain this error" | mdjam --stdin
echo "# Hello\n\`\`\`bash\necho hi\n\`\`\`" | mdjam --stdin
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
| `Tab` | Focus next executable block |
| `Enter` | Execute focused block |
| `Esc` | Cancel running block |
| `r` | Reload document |
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
| `teardown` | Bash script that runs on quit (`Ctrl+C`) |

If any prerequisite is unmet, mdjam exits immediately and prints why to stderr — the viewer never opens. If `setup` or `teardown` exits non-zero, mdjam's own exit code reflects that (execution isn't blocked, and an error banner is shown at the top of the document for a failed `setup`). Setup/teardown stdout is only shown with `--verbose`; stderr is always shown, printed to the real terminal once mdjam exits.

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

Downstream blocks receive every state store value as `MDJAM_<KEY>` environment variables:

```bash
echo "MY_KEY is: $MDJAM_MY_KEY"
```

Values written by a block with `id: my-block` are stored under both the bare key (`TOKEN`) and the namespaced key (`my-block.TOKEN`). Values written by `setup` use bare keys only.

### Block status indicators

The status bar shows a `[indicator]` badge for the focused block, except for
`idle` (nothing has happened yet) and `done` results from `auto: true`
execution (the user never asked to see them) — both are shown as no badge at all.

| Indicator | Meaning |
|---|---|
| spinner (`⠋⠙⠹⠸...`) | Script is running |
| `done` | Succeeded |
| `failed` | Exited non-zero |
| `cancelled` | Cancelled with `Esc` |
| `blocked` | Prerequisites failed |

## Using mdjam as an agent tool

The non-interactive pattern: pipe markdown in via `--stdin`, mark blocks `auto: true` so they run without keypresses, and use `--delegate` to forward the focused block's stdout/stderr and exit code back to the caller.

### Example — Claude Code tool configuration

Add this to your project's `CLAUDE.md` or `~/.claude/CLAUDE.md`:

```markdown
## Available tools

**mdjam** — run a markdown runbook non-interactively and capture output.

Usage:
  printf '%s' "$MARKDOWN" | mdjam --stdin --delegate --no-watch

- Mark bash fences with `auto: true` to execute them on load.
- `--delegate` forwards the focused block's stdout/stderr and mirrors its exit code.
- `echo "::set-output name=KEY::value"` inside a block captures KEY into the state store.
```

## Development

```bash
# Debug build and run
zig build run -- examples/01-hello.md

# Run tests
zig build test

# Format source
zig fmt src/

# Release build (statically linked)
zig build -Doptimize=ReleaseSafe

# Cross-compile
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe
```
