# Agent Instructions

## Environment

This project uses [mise](https://mise.jdx.dev) (`.mise.toml`) to pin the Bun version and [direnv](https://direnv.net) (`.envrc`) to activate it automatically. Both must be installed and hooked into the shell before running any project commands. Run `direnv allow` once after cloning to enable the `.envrc`.

## Runtime

This project targets **Bun** as the sole runtime. Never use Node.js or Node.js-specific tools.

- Use `bun` for all script execution, package management, building, and testing.
- Use `bun install` (not `npm install` / `yarn` / `pnpm`).
- Use `bun run` (not `node`, `ts-node`, `tsx`).
- Use `bun test` (not `jest`, `vitest`, `mocha`).
- Use `bun build` (not `webpack`, `esbuild` invoked directly, `tsc` for emit).
- Do not add `engines.node` or `.nvmrc`; use `engines.bun` in `package.json`.
- Do not add `tsconfig.json`; Bun transpiles TypeScript natively without it.
- Use `@types/bun` (not `@types/node`) for IDE type coverage of `node:*` builtins.

## Tooling preferences

- Use `jq` for JSON filtering and transformation, not Python.

## Allowed tools (no confirmation needed)

The following are always pre-approved:

- `tmux` — any tmux command (new sessions, splits, send-keys, etc.)
- Read-only CLI tools that do not modify state or require interactive input: `cat`, `ls`, `find`, `grep`, `rg`, `fd`, `jq`, `yq`, `wc`, `head`, `tail`, `diff`, `file`, `stat`, `which`, `type`, `env`, `printenv`, `git log`, `git diff`, `git status`, `git show`, `git blame`.
