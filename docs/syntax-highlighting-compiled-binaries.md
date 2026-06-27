# Syntax Highlighting in Compiled Binaries

## Problem

Bun 1.x `--compile` cannot embed worker scripts or WASM files in standalone
binaries. The `@opentui/core` syntax highlighter runs tree-sitter in a
dedicated worker thread (`parser.worker.js`) and loads WASM files at runtime
— none of which survive the compile step.

Tracked upstream at: https://github.com/oven-sh/bun/issues/6567

## Symptoms

- Bash code fences render without syntax colours in distributed binaries.
- `bun run src/cli.ts` (dev mode) is unaffected — it reads directly from
  `node_modules` and the worker loads normally.

## Why the Sidecar Approach

Three alternatives were evaluated:

| Approach | Outcome |
|---|---|
| `new Worker(new URL("./parser.worker.js", import.meta.url))` — rely on Bun's static worker detection | Bun 1.3.x does not detect this pattern in bundled `node_modules` files; the worker is never embedded. |
| `import foo from '...wasm' with { type: 'file' }` — embed WASM via file import | Files are embedded in `$bunfs` but the sidecar worker process cannot access the parent binary's virtual filesystem. |
| **Sidecar directory** — ship pre-bundled assets next to the binary | Works reliably. No Bun changes required. Implemented. |

## Current Workaround

A `mdjam-syntax/` directory is distributed alongside every binary. It contains
a self-contained build of `parser.worker.js` (including the core `tree-sitter.wasm`
it needs) plus the bash-specific language assets.

```
mdjam-linux-x64          ← compiled binary
mdjam-syntax/
  parser.worker.js       ← bundled: @opentui/core worker + web-tree-sitter JS
  tree-sitter-*.wasm     ← core tree-sitter WASM (content-hashed by Bun)
  bash/
    tree-sitter-bash.wasm
    highlights.scm
mdjam-syntax.tar.gz      ← tarball of the above for install.sh
SHA256SUMS
```

`cli.ts` detects the sidecar at startup:

```ts
const _sidecarDir = join(dirname(process.execPath), 'mdjam-syntax')
const _useSidecar = existsSync(join(_sidecarDir, 'parser.worker.js'))

if (_useSidecar) {
  process.env.OTUI_TREE_SITTER_WORKER_PATH = join(_sidecarDir, 'parser.worker.js')
}
```

`OTUI_TREE_SITTER_WORKER_PATH` is read by `@opentui/core`'s `TreeSitterClient`
before it spawns the worker thread, so no patching of library internals is
needed for this part. The bash WASM/query paths follow the same sidecar-or-
`createRequire` pattern.

The sidecar is built in `scripts/release.sh` via:

```bash
bun build node_modules/@opentui/core/parser.worker.js \
  --outdir "$OUTDIR/mdjam-syntax" \
  --target bun
```

Bun automatically copies `tree-sitter.wasm` alongside the bundled worker because
`web-tree-sitter` references it via a relative path that Bun resolves as an asset.

## How to Properly Fix This

The sidecar is a workaround. The right fix is for Bun to embed workers and WASM
in compiled binaries. Once that is resolved upstream, the path forward is:

1. Remove the sidecar build step from `scripts/release.sh`.
2. Remove the sidecar detection block from `src/cli.ts` and replace it with
   static file imports:

   ```ts
   import bashWasm from 'tree-sitter-bash/tree-sitter-bash.wasm' with { type: 'file' }
   import bashHighlights from 'tree-sitter-bash/queries/highlights.scm' with { type: 'file' }
   ```

3. Restore the `@opentui/core` patch in `patches/@opentui%2Fcore@0.4.1.patch`
   to use `new Worker(new URL("./parser.worker.js", import.meta.url))` directly
   so Bun embeds the worker at compile time.
4. Remove `mdjam-syntax` handling from `install.sh`.
5. Verify with `bun build src/cli.ts --compile` that syntax colours appear in a
   compiled binary without the sidecar directory present.

Track Bun issue progress at: https://github.com/oven-sh/bun/issues/6567
