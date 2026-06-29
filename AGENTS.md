# Agent Instructions

## Environment

This project uses [mise](https://mise.jdx.dev) (`.mise.toml`) to pin the Zig and ZLS versions, and [direnv](https://direnv.net) (`.envrc`) to activate them automatically. Both must be installed and hooked into the shell before running any project commands. Run `direnv allow` once after cloning to enable the `.envrc`.

## Runtime

This project is implemented in **Zig 0.16**. There is no Node.js, Bun, or npm involvement.

- Use `zig build` to compile.
- Use `zig build run -- <file.md>` to run.
- Use `zig build test` to run tests.
- Use `zig fmt src/` to format source files.
- Do not add `package.json`, `bun.lock`, or any npm/yarn/pnpm files.

## Build

```bash
# Debug build
zig build

# Run directly
zig build run -- examples/01-hello.md

# Release build (statically linked, optimised)
zig build -Doptimize=ReleaseSafe

# Cross-compile (example: Linux arm64 musl)
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe
```

## Project layout

```
build.zig          Zig build script
build.zig.zon      Dependency manifest (vaxis for TUI)
src/
  main.zig         Entry point, CLI arg parsing
  app.zig          Root TUI widget, document load/reload
  theme.zig        Color theme definitions
  parser/
    markdown.zig   GFM-subset markdown AST parser
    frontmatter.zig YAML frontmatter parser (title, prerequisites, setup, teardown, defaults)
    fence_meta.zig  Code fence metadata parser (# ---...# --- YAML block)
    dependency.zig  Dependency graph, topological sort
  engine/
    state_store.zig   Thread-safe key-value state store
    block_runner.zig  Async bash execution via std.Thread + POSIX I/O
    lifecycle.zig     Setup/teardown script runner
    prerequisites.zig Tool/env prerequisite checking
  components/
    document_view.zig  Scrollable markdown document widget
    code_fence.zig     Executable code block widget
    status_bar.zig     Bottom keyboard-hint bar
    state_panel.zig    Toggleable state store side panel
    help_panel.zig     Toggleable keyboard help overlay
examples/          Sample .md files for manual testing
```

## Key implementation notes

- `std.process.Child` spawning and pipe I/O use raw POSIX `read()`/`waitpid()` calls (bypassing `std.Io.Threaded` scheduler which deadlocks when called from `std.Thread`).
- The vxfw event loop (libvaxis) is woken via a tick command issued from `App.handleEvent` whenever block execution threads are running.
- YAML parsing for frontmatter and fence metadata is a minimal hand-rolled subset — not a full YAML library.

## Allowed tools (no confirmation needed)

The following are always pre-approved:

- `tmux` — any tmux command (new sessions, splits, send-keys, etc.)
- Read-only CLI tools that do not modify state or require interactive input: `cat`, `ls`, `find`, `grep`, `rg`, `fd`, `jq`, `yq`, `wc`, `head`, `tail`, `diff`, `file`, `stat`, `which`, `type`, `env`, `printenv`, `git log`, `git diff`, `git status`, `git show`, `git blame`.
