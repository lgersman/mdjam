import { parseArgs } from 'node:util'
import { resolve } from 'node:path'
import { existsSync } from 'node:fs'
import { runApp } from './app.js'
import type { ThemeName } from './theme/themes.js'

const HELP = `\
Usage: mdrun <file> [options]

Terminal markdown viewer with executable code fences

Arguments:
  <file>             Markdown file to open

Options:
  --no-auto          Suppress auto-execution of auto:true blocks
  --no-watch         Disable watch mode (default: enabled)
  --theme <name>     Syntax theme: github-dark | github-light | dracula  (default: github-dark)
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
    auto:    { type: 'boolean', default: true },
    watch:   { type: 'boolean', default: true },
    theme:   { type: 'string',  default: 'github-dark' },
    version: { type: 'boolean', default: false },
    help:    { type: 'boolean', default: false },
  },
})

if (values.help) {
  process.stdout.write(HELP)
  process.exit(0)
}

if (values.version) {
  process.stdout.write('0.1.0\n')
  process.exit(0)
}

if (positionals.length === 0) {
  process.stderr.write('Error: missing required argument <file>\n')
  process.exit(1)
}

const filePath = resolve(positionals[0])

if (!existsSync(filePath)) {
  process.stderr.write(`Error: File not found: ${filePath}\n`)
  process.exit(1)
}

const theme = (values.theme ?? 'github-dark') as ThemeName
const validThemes: ThemeName[] = ['github-dark', 'github-light', 'dracula']
if (!validThemes.includes(theme)) {
  process.stderr.write(`Error: Unknown theme '${theme}'. Valid themes: ${validThemes.join(', ')}\n`)
  process.exit(1)
}

await runApp({
  filePath,
  theme,
  noAuto: !values.auto,
  noWatch: !values.watch,
})
