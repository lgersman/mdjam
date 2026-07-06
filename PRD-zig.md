# PRD: mdjam — Zig Rewrite

**Status:** Draft  
**Date:** 2026-06-29  
**Author:** lgersman  
**Supersedes:** PRD.md (Bun/TypeScript implementation)

---

## 1. Overview

A terminal-based markdown viewer that renders `.md` files with full formatting and allows individual code fence blocks to be **executed inline**. Scripts in code fences can run, produce output that appears directly beneath the fence, export named values consumed by later fences, declare typed inputs, and express dependencies on other fences. The result is a self-documenting, interactive runbook format usable from any terminal.

This document describes a full rewrite of the existing Bun/TypeScript implementation in Zig, using OpenTUI directly as a native Zig dependency rather than via `bun:ffi`. The functional specification is identical to the original PRD; this document updates goals, architecture, stack, and file structure to reflect the new implementation language.

---

## 2. Motivation for the Rewrite

The TypeScript implementation has one structural constraint: it requires the Bun runtime. Bun is the only JavaScript runtime that can call into OpenTUI's Zig-compiled shared library via `bun:ffi`. This makes the distributed binary large and installation non-trivial.

Since OpenTUI is itself written in Zig, rewriting mdjam in Zig eliminates the FFI layer entirely: OpenTUI becomes a direct Zig package dependency, called at the language level with no ABI indirection. The result is a fully static binary with no runtime dependency.

---

## 3. Goals

- Preserve all functional behaviour described in PRD.md verbatim.
- Replace the Bun runtime with a fully static, self-contained binary.
- Integrate OpenTUI directly as a Zig package (`build.zig.zon`) — no FFI, no shared library loading at runtime.
- Use the Zig toolchain exclusively: `zig build`, `zig test`, `zig fmt`.
- Provide the same CLI interface and keyboard map as the TypeScript version.
- Produce binaries for Linux (x86-64, aarch64) and macOS (x86-64, aarch64) via cross-compilation.

## 4. Non-Goals

- Support for languages other than `bash`/`sh` in the execution engine (v1).
- A file browser or multi-file workspace.
- Remote markdown fetching (URL support).
- Windows support (v1 targets Linux/macOS).
- A REPL or persistent shell session across blocks (each block runs in a fresh subshell that inherits exported state).
- Parity with the TypeScript prototype during the transition — the Zig version replaces it, it does not run alongside it.

---

## 4. Target Users

| Persona | Use Case |
|---|---|
| DevOps / SRE | Interactive runbooks: deploy steps with inline output verification |
| Developer onboarding | Setup guides that self-verify tool availability and run install steps |
| Data engineer | Pipeline notebooks: fetch → transform → load with visible intermediate state |
| Security researcher | Audit playbooks with dependent enumeration steps |

---

## 5. Functional Requirements

Functional requirements FR-01 through FR-42 are carried over from PRD.md without change. They are not repeated here to avoid duplication; this document is authoritative only for architecture and stack decisions.

Key requirements preserved verbatim:
- GFM rendering (FR-01 to FR-04, FR-42)
- Document-level YAML frontmatter: prerequisites, setup, teardown, defaults (FR-05 to FR-08)
- Code fence metadata via YAML comment block: id, description, auto, inputs, outputs, depends, interactive (FR-09, FR-10)
- Input rendering and editing (FR-11 to FR-15)
- Code fence execution: spawn, stream, status, cancel (FR-16 to FR-23)
- Inter-block data exchange via `::set-output` and `export` capture (FR-24 to FR-28, FR-41)
- Dependency execution and topological ordering (FR-29 to FR-31)
- Auto-execute (FR-32 to FR-34)
- Lifecycle scripts: setup and teardown (FR-35 to FR-40)

---

## 6. TUI Behaviour and Navigation

Keyboard map, focus model, and block status indicators are identical to PRD.md §7. No changes.

---

## 7. CLI Interface

```
mdjam [options] <file.md>
mdjam [options] --stdin

Options:
  --no-auto          Suppress auto-execution of auto:true blocks
  --watch            Reload document on file change (default: enabled)
  --no-watch         Disable watch mode
  --theme <name>     Syntax theme: dark | light | dracula | tokyo-night  [default: dark]
  --stdin            Read markdown from stdin instead of a file
  --verbose          Show document frontmatter as a YAML header above the document
  --delegate         On exit, forward the focused block's stdout/stderr and exit code to the shell
  --agent-docs       Print agent-optimized CLI reference and exit
  -h, --help         Show help
  -v, --version      Print version
```

---

## 8. Technical Architecture

### 8.1 Stack

| Layer | Choice | Rationale |
|---|---|---|
| Language | Zig 0.16 | Same language as OpenTUI; zero-FFI native integration; static binary output |
| Build | `zig build` | Native Zig build system; cross-compilation built-in |
| Test | `zig test` | Built into the Zig toolchain; no additional dependency |
| TUI rendering | `opentui` (Zig package) | Direct Zig dependency; identical API surface to the TS version, minus the FFI layer |
| Markdown parsing | [Koino](https://github.com/kivikakk/koino) | Pure Zig, MIT, 100% GFM spec-compliant (671/671 tests); added via `zig fetch` |
| Syntax highlighting | [Zigdown](https://github.com/JacobCrabill/zigdown) highlighting layer | Pure Zig, MIT, tree-sitter-backed; supports bash, C, Python, Rust, Zig and more |
| YAML parsing | `zig-yaml` or inline minimal parser | Frontmatter and fence metadata are simple flat YAML; a minimal parser suffices for v1 |
| Script execution | `std.process.Child` | Stdlib; pipe stdout/stderr, inject env, capture exit code |
| Async / event loop | `std.Thread` + [libxev](https://github.com/mitchellh/libxev) | Scripts run on threads; libxev drives the TUI event loop without blocking |
| File watching | `std.fs.Watch` (0.16+) or inotify via `std.os` | Stdlib-only; no extra dependency |

### 8.2 Fence Metadata — Custom Fields

The fence metadata YAML comment block (`# ---…# ---`) is mdjam-specific and not part of any markdown spec. Both Koino and Zigdown expose the raw fence body; metadata parsing is handled by a small purpose-built parser in `src/parser/metadata.zig` that strips the comment block and returns a `FenceMetadata` struct.

### 8.3 Rendering Pipeline

```
File read  (std.fs.File)
  │
  ▼
FrontmatterParser          (strip leading YAML block; populate FrontmatterData)
  │
  ▼
PrerequisiteChecker        (std.process.Child: which/type for tools; std.os.getenv for vars)
  │
  ▼
LifecycleRunner.setup      (std.process.Child; env snapshot diff; ::set-output → StateStore)
  │  on failure → SetupErrorPanel shown at top; all fence execution blocked
  │
  ▼
KoinoParser                (parse GFM → AST)
  │  walk AST; intercept code nodes with lang=bash/sh/toc
  │
  ├─► MetadataParser       (strips # --- ... # --- YAML block from fence body)
  │
  └─► CodeFenceComponent   (custom OpenTUI component per fence)
        ├─ InputRow[]      (editable TextField | readonly DisplayRow, rendered above fence)
        ├─ FenceBody       (ZigdownHighlighter, read-only display)
        ├─ StatusBar       (execution state, keyboard hint)
        └─ OutputPanel     (streaming stdout/stderr, collapsible)

on viewer exit →
LifecycleRunner.teardown   (std.process.Child; full StateStore injected as MDJAM_* env)
  │  output → TeardownPanel rendered briefly before process exits
```

### 8.4 Execution Engine

```
ExecutionEngine
  ├─ StateStore           thread-safe HashMap([]const u8, []const u8); Mutex-guarded; change notifications via std.Thread.Condition or libxev callbacks
  ├─ DependencyResolver   topological sort (Kahn's algorithm); cycle detection at parse time
  ├─ LifecycleRunner      setup (before render) and teardown (on exit)
  │    ├─ snapshots env before execution; diffs after to capture plain exports
  │    └─ intercepts ::set-output lines → StateStore.set() (bare KEY for setup)
  └─ BlockRunner
       ├─ strips metadata comment lines from script body
       ├─ snapshots env before execution; diffs after to capture plain exports
       ├─ injects StateStore as MDJAM_* environment variables
       ├─ spawns /bin/bash -c <script> via std.process.Child
       ├─ intercepts ::set-output lines → StateStore.set() (namespaced <block-id>.KEY)
       └─ pipes remaining stdout/stderr → OutputPanel stream (libxev async reads)
```

### 8.5 Concurrency Model

Zig 0.13+ removed `async/await`. The event model is:

- **TUI event loop**: driven by libxev on the main thread. Keyboard, resize, and output-stream events are dispatched here.
- **Script execution**: each `BlockRunner.run()` spawns a `std.Thread`. The thread reads stdout/stderr in a loop and posts line events to libxev's event loop via a thread-safe channel (libxev `Async` handle), which delivers them to the OutputPanel on the main thread.
- **StateStore**: protected by a `std.Thread.Mutex`; readers and writers lock per access.
- **Cancellation**: `BlockRunner` holds the `std.process.Child` handle; `cancel()` sends `SIGTERM`, then `SIGKILL` after 3 seconds via a libxev timer.

### 8.6 Component Tree

```
App
├─ PrerequisitePanel       (shown when any prerequisite fails)
├─ SetupErrorPanel         (shown when setup script exits non-zero; blocks all fence execution)
├─ FrontmatterPanel        (editable input panel for document-wide defaults declared in frontmatter)
├─ StateSidePanel          (toggleable overlay; shows StateStore contents)
├─ HelpPanel               (toggleable overlay; shows keyboard map)
├─ ScrollableDocument
│    └─ MarkdownView       (walks Koino AST; mounts OpenTUI renderables per node)
│         ├─ [standard nodes: headings, paragraphs, lists, tables…]
│         ├─ TocComponent           (interactive table of contents for `toc` fences)
│         └─ CodeFenceComponent[]
│              ├─ InputRow[]        (editable TextField | readonly DisplayRow, above fence)
│              ├─ FenceBody         (ZigdownHighlighter output, read-only)
│              ├─ StatusBar         (execution state, keyboard hint)
│              └─ OutputPanel       (streaming stdout/stderr, collapsible)
└─ TeardownPanel           (rendered on exit; shows teardown script output before process ends)
```

### 8.7 Known Implementation Gaps vs. TypeScript Version

| Gap | Notes |
|---|---|
| Shiki theme fidelity | Shiki (TypeScript) supports hundreds of themes via VS Code TextMate grammars. Zigdown's tree-sitter-backed highlighter uses a smaller token set. The four named themes (dark, light, dracula, tokyo-night) will need manual colour mappings to Zigdown's token categories. |
| Koino fenced metadata | Koino exposes the raw fence body string; it does not parse mdjam's `# ---…# ---` comment block. The `MetadataParser` must strip and parse this before passing the clean body to Zigdown. |
| PTY / interactive blocks | `std.process.Child` supports pipe-based I/O. Interactive blocks (`interactive: true`) require a PTY. This needs `posix_openpt` / `forkpty` via `std.os` or a thin C shim. Defer to v1.1. |
| YAML parsing | Frontmatter and fence metadata are structurally simple. A minimal recursive-descent YAML subset parser is sufficient for v1; a full YAML library can be added later if edge cases arise. |

---

## 9. Proposed File Structure

```
mdjam/
├─ build.zig                   Zig build script; declares deps, test, install targets
├─ build.zig.zon               Dependency manifest (opentui, koino, zigdown, libxev)
├─ src/
│   ├─ main.zig                entry point; arg parsing; calls app.run()
│   ├─ app.zig                 top-level TUI app; event loop; keyboard handler
│   ├─ parser/
│   │   ├─ frontmatter.zig     strip and parse leading YAML frontmatter block
│   │   ├─ metadata.zig        parse # ---…# --- YAML comment block in fence body
│   │   └─ dependency.zig      dependency graph; topological sort; cycle detection
│   ├─ engine/
│   │   ├─ state_store.zig     thread-safe HashMap; change notifications
│   │   ├─ block_runner.zig    spawn bash; stream stdout/stderr; ::set-output interception
│   │   ├─ lifecycle_runner.zig setup/teardown execution; env diff; bare-key store writes
│   │   ├─ execution_engine.zig dep resolution; block orchestration
│   │   ├─ prerequisites.zig   tool/env prerequisite checking
│   │   └─ script_utils.zig    env snapshot/diff; ::set-output line parsing
│   ├─ components/
│   │   ├─ prerequisite_panel.zig
│   │   ├─ setup_error_panel.zig
│   │   ├─ teardown_panel.zig
│   │   ├─ frontmatter_panel.zig
│   │   ├─ state_side_panel.zig
│   │   ├─ help_panel.zig
│   │   ├─ code_fence_component.zig
│   │   ├─ toc_component.zig
│   │   ├─ input_row.zig
│   │   ├─ status_bar.zig
│   │   └─ output_panel.zig
│   └─ theme/
│       ├─ themes.zig          SyntaxStyle definitions (dark, light, dracula, tokyo-night)
│       └─ colors.zig          shared color primitives
└─ test/
    ├─ parser/
    ├─ engine/
    └─ fixtures/               sample .md files for integration tests
```

---

## 10. Build and Distribution

```bash
# development build
zig build

# run directly
zig build run -- examples/demo.md

# test
zig build test

# release build (optimised, stripped)
zig build -Doptimize=ReleaseSafe

# cross-compile for macOS arm64 from Linux
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe
```

The release binary is statically linked and has no runtime dependencies. The existing `install.sh` script can be reused with the new binary artifact path.

---

## 11. Development Environment

Tooling is managed via mise and activated automatically by direnv:

```toml
# .mise.toml
[tools]
bun = "1.3.14"   # retained for the TypeScript prototype during transition
zig = "0.16.0"
zls = "0.16.0"   # Zig Language Server for IDE support
```

`.envrc` already contains `use mise`; no additional direnv configuration is needed.

---

## 12. Open Questions / Deferred Decisions

| # | Question | Notes |
|---|---|---|
| OQ-1 | Keep or drop the TypeScript implementation once the Zig version reaches feature parity? | Recommend keeping `PRD.md` and the TS source until the Zig build passes all integration tests |
| OQ-2 | YAML library: inline minimal parser vs. a full Zig YAML library? | v1: minimal parser; revisit if nested mapping or multiline strings in frontmatter cause issues |
| OQ-3 | PTY for interactive blocks: `forkpty` C shim or wait for Zig stdlib support? | Defer to v1.1; document `interactive: true` as unsupported in v1 |
| OQ-4 | Zigdown theme mapping: define manually or generate from Shiki token names? | Manual for the four named themes; 50–60 token categories to map |
| OQ-5 | All open questions from PRD.md OQ-1 through OQ-8 carry over unchanged | |

---

## 13. Success Metrics

Identical to PRD.md §13:

- A 5-step runbook with a full dependency chain executes end-to-end without the user leaving the terminal.
- All prerequisites checked and reported within 200 ms of viewer startup.
- Streaming output latency < 50 ms from process write to TUI display.
- Cold start (parse + render a 500-line `.md` file) < 300 ms.
- Distributed binary size < 5 MB (static, stripped, ReleaseSafe).
