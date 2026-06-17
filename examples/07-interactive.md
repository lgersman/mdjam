---
title: Interactive — embedded terminal sessions
---

# Interactive blocks

Add `interactive: true` to run a bash block inside a real PTY session.
The TUI pauses, you interact naturally with the program, and on exit the output
appears below the block — just like any regular run.

Use this for scripts that need keyboard input, full-screen TUI tools, or anything
that a regular piped shell can't handle.

---

## Simple prompt

A `read` call in a regular block silently hangs — no terminal to read from.
With `interactive: true` it works as expected.

```bash
# ---
# id: greet
# description: Ask for your name interactively
# interactive: true
# ---
echo "What is your name?"
read -r name
echo "Hello, $name!"
export GREETED_NAME="$name"
```

---

## Interactive selection → downstream block

The `select` built-in shows a numbered menu. The chosen value is passed to the
next block via `::set-output`.

```bash
# ---
# id: pick-env
# description: Choose a deployment target
# interactive: true
# outputs:
#   - env
# ---
echo "Deploy to which environment?"
select env in development staging production; do
  [ -n "$env" ] && break
  echo "Invalid choice, try again."
done
echo "::set-output name=env::$env"
echo "Selected: $env"
```

Run **deploy** below — `pick-env` runs first automatically.

```bash
# ---
# id: deploy
# description: Deploy to the chosen environment
# depends:
#   - pick-env
# ---
echo "Deploying to: $MDFENCE_ENV"
sleep 0.5
echo "✓ Deployed (simulated)"
```

---

## Full-screen TUI tools

Any full-screen program works. Here `nano` edits a temp file; the path is
exported so a downstream block can read it.

```bash
# ---
# id: edit-config
# description: Edit a config snippet in nano
# interactive: true
# outputs:
#   - config_path
# ---
config=$(mktemp /tmp/mdrun-config-XXXX.toml)
cat > "$config" <<'EOF'
[server]
host = "localhost"
port   = 8080
debug  = false
EOF

nano "$config"

echo "::set-output name=config_path::$config"
echo "Saved: $config"
```

```bash
# ---
# id: show-config
# description: Print the edited config
# depends:
#   - edit-config
# ---
echo "=== $MDFENCE_CONFIG_PATH ==="
cat "$MDFENCE_CONFIG_PATH"
```

---

## Notes

- The TUI suspends for the full duration of the session; no other blocks can run.
- `::set-output` lines are intercepted from the session transcript after exit.
- Variables exported with `export` are captured in the state store on exit.
- `auto: true` and `interactive: true` together will suspend the TUI immediately on load — use with care.
