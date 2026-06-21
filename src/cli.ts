#!/usr/bin/env bun
import { parseArgs } from 'node:util'
import { resolve, dirname, join } from 'node:path'
import { existsSync } from 'node:fs'
import { createRequire } from 'node:module'
import { addDefaultParsers } from '@opentui/core'
import { runApp } from './app.js'
import type { ThemeName } from './theme/themes.js'
import pkg from '../package.json'

const _require = createRequire(import.meta.url)
const bashPkgDir = dirname(_require.resolve('tree-sitter-bash/package.json'))
addDefaultParsers([{
  filetype: 'bash',
  aliases: ['sh', 'shell'],
  wasm: join(bashPkgDir, 'tree-sitter-bash.wasm'),
  queries: { highlights: [join(bashPkgDir, 'queries/highlights.scm')] },
}])

const HELP = `\
Usage: mdrun <file> [options]
       mdrun --stdin [options]

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
  --version          Show version
  --help             Show this help
`

if (process.argv.length <= 2) {
  process.stdout.write(HELP)
  process.exit(0)
}

const { values, positionals } = parseArgs({
  args: process.argv.slice(2),
  allowPositionals: true,
  options: {
    stdin:    { type: 'boolean', default: false },
    auto:     { type: 'boolean', default: true },
    watch:    { type: 'boolean', default: true },
    theme:    { type: 'string',  default: 'dark' },
    verbose:  { type: 'boolean', default: false },
    delegate: { type: 'boolean', default: false },
    version:  { type: 'boolean', default: false },
    help:     { type: 'boolean', default: false },
  },
})

if (values.help) {
  process.stdout.write(HELP)
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
    noAuto: !values.auto,
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
    noAuto: !values.auto,
    noWatch: !values.watch,
    verbose: values.verbose ?? false,
    delegate: values.delegate ?? false,
  })
}
