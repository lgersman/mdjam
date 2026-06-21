---
description: Hello — mdjam basics
---

# Hello, mdjam

A terminal markdown viewer where bash code blocks run inline.
Use **Tab** to move focus to a block, **Enter** to run it.

## Your first block

```bash
echo "Hello from mdjam!"
echo "Running as: $USER"
echo "In: $PWD"
```

## Auto-execution

Blocks with `auto: true` run the moment the document loads — no keypress needed.

```bash
# ---
# auto: true
# description: Shows your system at a glance
# ---
echo "OS:    $(uname -s) $(uname -r)"
echo "Shell: $SHELL"
echo "Cores: $(nproc)"
echo "Date:  $(date)"
```

## Inline output

Each block's stdout and stderr appear directly below it.
A status bar shows idle / running / success / failed.

```bash
echo "stdout line 1"
echo "stdout line 2"
echo "an error" >&2
exit 0
```

## Failing block

A non-zero exit code marks the block as **failed** (red status bar).

```bash
echo "This will fail"
exit 1
```

---

## Keyboard map

| Key | Action |
|-----|--------|
| `Tab` / `Shift+Tab` | Focus next / previous block |
| `Enter` | Run the focused block |
| `Esc` | Cancel a running block |
| `j` / `↓` | Scroll down |
| `k` / `↑` | Scroll up |
| `Space` / `PgDn` | Page down |
| `b` / `PgUp` | Page up |
| `g` / `G` | Jump to top / bottom |
| `r` | Reload the document |
| `s` | Toggle state panel |
| `?` | Show / hide keyboard help |
| `Ctrl+C` | Quit (runs teardown if defined) |
