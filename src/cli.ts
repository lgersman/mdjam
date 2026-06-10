import { Command } from 'commander'
import { resolve } from 'node:path'
import { existsSync } from 'node:fs'
import { runApp } from './app.js'
import type { ThemeName } from './theme/themes.js'

const program = new Command()

program
  .name('mdrun')
  .description('Terminal markdown viewer with executable code fences')
  .version('0.1.0')
  .argument('<file>', 'Markdown file to open')
  .option('--no-auto', 'Suppress auto-execution of auto:true blocks')
  .option('--no-watch', 'Disable watch mode (default: watch enabled)')
  .option(
    '--theme <name>',
    'Syntax theme: github-dark | github-light | dracula',
    'github-dark',
  )
  .action(async (file: string, opts: {
    auto: boolean
    watch: boolean
    theme: string
  }) => {
    const filePath = resolve(file)

    if (!existsSync(filePath)) {
      console.error(`Error: File not found: ${filePath}`)
      process.exit(1)
    }

    const theme = (opts.theme ?? 'github-dark') as ThemeName
    const validThemes: ThemeName[] = ['github-dark', 'github-light', 'dracula']
    if (!validThemes.includes(theme)) {
      console.error(`Error: Unknown theme '${theme}'. Valid themes: ${validThemes.join(', ')}`)
      process.exit(1)
    }

    await runApp({
      filePath,
      theme,
      noAuto: !opts.auto,
      noWatch: !opts.watch,
    })
  })

program.parse()
