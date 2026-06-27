#!/usr/bin/env bun
import { parseArgs } from 'node:util'
import { resolve, dirname, join } from 'node:path'
import { existsSync } from 'node:fs'
import { createRequire } from 'node:module'
import { addDefaultParsers } from '@opentui/core'
import { runApp } from './app.js'
import type { ThemeName } from './theme/themes.js'
import pkg from '../package.json'

// Bun 1.x compiled binaries cannot embed workers or WASM files.
// We use a sidecar directory (mdjam-syntax/) next to the binary that ships
// a pre-bundled parser.worker.js plus language WASM files.
const _sidecarDir = join(dirname(process.execPath), 'mdjam-syntax')
const _useSidecar = existsSync(join(_sidecarDir, 'parser.worker.js'))

if (_useSidecar) {
  process.env.OTUI_TREE_SITTER_WORKER_PATH = join(_sidecarDir, 'parser.worker.js')
}

const _bashWasm = _useSidecar
  ? join(_sidecarDir, 'bash', 'tree-sitter-bash.wasm')
  : (() => {
    const _require = createRequire(import.meta.url)
    return join(dirname(_require.resolve('tree-sitter-bash/package.json')), 'tree-sitter-bash.wasm')
  })()

const _bashHighlights = _useSidecar
  ? join(_sidecarDir, 'bash', 'highlights.scm')
  : (() => {
    const _require = createRequire(import.meta.url)
    return join(dirname(_require.resolve('tree-sitter-bash/package.json')), 'queries', 'highlights.scm')
  })()

addDefaultParsers([{
  filetype: 'bash',
  aliases: ['sh', 'shell'],
  wasm: _bashWasm,
  queries: { highlights: [_bashHighlights] },
}])

const HELP = `\
Usage: mdjam <file> [options]
       mdjam --stdin [options]

Terminal markdown viewer with executable code fences

Arguments:
  <file>             Markdown file to open

Options:
  --stdin            Read markdown from stdin
  --no-auto          Suppress auto-execution of auto:true blocks
  --no-watch         Disable watch mode (default: enabled)
  --theme <name>     Syntax theme: dark | light | dracula | tokyo-night  (default: dark)
  --verbose          Show document frontmatter as a header
  --delegate         On exit, write the focused block's stdout/stderr and use its exit code
  --agent-docs       Print agent-optimised reference and exit
  --version          Show version
  --help             Show this help
`

const AGENT_DOCS = `\
mdjam — execute bash code fences in a markdown document

USAGE (non-interactive / agent):
  printf '%s' "$MARKDOWN" | mdjam --stdin --delegate --no-watch
  mdjam --delegate --no-watch <file.md>

FLAGS FOR AGENTS:
  --stdin        Read markdown from stdin (watch disabled automatically)
  --delegate     On exit: forward focused block stdout→stdout, stderr→stderr, mirror exit code
  --no-auto      Suppress auto:true blocks
  --no-watch     Disable file reload; always set for non-interactive use

EXIT CODES:
  0    Success (or --delegate: block exited 0)
  1    Bad args / file not found / prerequisite or setup script failed
  -1   --delegate: selected block was not executed

AUTO-EXECUTION:
  Blocks marked auto:true run on load without keypresses.
  mdjam exits when all auto blocks have finished and no interactive inputs are pending.

BLOCK METADATA (YAML comment header inside a bash fence):
  \`\`\`bash
  # ---
  # id: step1
  # auto: true
  # outputs: [RESULT]
  # ---
  echo "::set-output name=RESULT::$(compute_something)"
  \`\`\`

OUTPUT PROTOCOL:
  echo "::set-output name=KEY::value"   # silent capture into state store
  export KEY=value                      # exported vars also captured into state store

DOWNSTREAM BLOCKS receive state store values as MDJAM_<KEY> environment variables.

EXAMPLE — pipe generated markdown, capture result:
  md=\$(cat <<'EOF'
  \`\`\`bash
  # ---
  # auto: true
  # outputs: [STATUS]
  # ---
  export STATUS=done
  \`\`\`
  EOF
  )
  result=\$(printf '%s' "\$md" | mdjam --stdin --delegate --no-watch)
  echo "exit=\$? result=\$result"
`

if (process.argv.length <= 2) {
  process.stdout.write(HELP)
  process.exit(0)
}

const { values, positionals } = parseArgs({
  args: process.argv.slice(2),
  allowPositionals: true,
  options: {
    stdin:        { type: 'boolean', default: false },
    'no-auto':    { type: 'boolean', default: false },
    'no-watch':   { type: 'boolean', default: false },
    theme:        { type: 'string',  default: 'dark' },
    verbose:      { type: 'boolean', default: false },
    delegate:     { type: 'boolean', default: false },
    'agent-docs': { type: 'boolean', default: false },
    version:      { type: 'boolean', default: false },
    help:         { type: 'boolean', default: false },
  },
})

if (values.help) {
  process.stdout.write(HELP)
  process.exit(0)
}

if (values['agent-docs']) {
  process.stdout.write(AGENT_DOCS)
  process.exit(0)
}

if (values.version) {
  process.stdout.write(`${pkg.version}\n`)
  process.exit(0)
}

const theme = (values.theme ?? 'dark') as ThemeName
const validThemes: ThemeName[] = ['dark', 'light', 'dracula', 'tokyo-night']
if (!validThemes.includes(theme)) {
  process.stderr.write(`Error: Unknown theme '${theme}'. Valid themes: ${validThemes.join(' | ')}\n`)
  process.exit(1)
}

if (values.stdin) {
  const content = await Bun.stdin.text()
  await runApp({
    content,
    theme,
    noAuto: values['no-auto'] ?? false,
    noWatch: true,
    verbose: values.verbose ?? false,
    delegate: values.delegate ?? false,
  })
} else {
  if (positionals.length === 0) {
    process.stderr.write('Error: missing required argument <file>\n')
    process.exit(1)
  }

  const filePath = resolve(positionals[0])

  if (!existsSync(filePath)) {
    process.stderr.write(`Error: File not found: ${filePath}\n`)
    process.exit(1)
  }

  await runApp({
    filePath,
    theme,
    noAuto: values['no-auto'] ?? false,
    noWatch: values['no-watch'] ?? false,
    verbose: values.verbose ?? false,
    delegate: values.delegate ?? false,
  })
}
