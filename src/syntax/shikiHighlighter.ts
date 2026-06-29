import { createHighlighter, type Highlighter } from 'shiki'
import type { SyntaxStyle } from '@opentui/core'
import type { ThemeName } from '../theme/themes.js'

const SHIKI_THEME_MAP: Record<ThemeName, string> = {
  'dark':        'github-dark',
  'light':       'github-light',
  'dracula':     'dracula',
  'tokyo-night': 'tokyo-night',
}

// Common languages loaded upfront; unknown langs are caught at tokenize time
const SHIKI_LANGS = [
  'bash', 'sh', 'shell',
  'javascript', 'js', 'jsx', 'typescript', 'ts', 'tsx',
  'python', 'py',
  'rust', 'go', 'java', 'c', 'cpp',
  'css', 'scss', 'html', 'xml',
  'json', 'yaml', 'toml',
  'sql', 'ruby', 'php', 'swift', 'kotlin',
  'markdown', 'diff', 'dockerfile', 'makefile',
] as const

let highlighterPromise: Promise<Highlighter> | null = null

function getHighlighter(): Promise<Highlighter> {
  if (!highlighterPromise) {
    highlighterPromise = createHighlighter({
      themes: Object.values(SHIKI_THEME_MAP),
      langs: [...SHIKI_LANGS],
    })
  }
  return highlighterPromise
}

// Call early to warm up the highlighter before the first render
export function preloadShikiHighlighter(): void {
  getHighlighter().catch(() => {})
}

// Track which style names are already registered per SyntaxStyle instance
const registeredStyles = new WeakMap<SyntaxStyle, Set<string>>()

function buildHighlights(
  tokenResult: { tokens: { content: string; offset: number; color?: string; fontStyle?: number }[][] },
  syntaxStyle: SyntaxStyle,
): [number, number, string][] {
  let registered = registeredStyles.get(syntaxStyle)
  if (!registered) {
    registered = new Set<string>()
    registeredStyles.set(syntaxStyle, registered)
  }

  const result: [number, number, string][] = []

  for (const line of tokenResult.tokens) {
    for (const token of line) {
      if (!token.color || !token.content) continue

      const color = token.color.toLowerCase()
      const fs = token.fontStyle ?? 0
      const bold      = (fs & 2) !== 0
      const italic    = (fs & 1) !== 0
      const underline = (fs & 4) !== 0

      const styleName =
        `shiki_${color.replace('#', '')}` +
        (bold ? 'b' : '') +
        (italic ? 'i' : '') +
        (underline ? 'u' : '')

      if (!registered.has(styleName)) {
        registered.add(styleName)
        const def: { fg: string; bold?: boolean; italic?: boolean; underline?: boolean } = { fg: color }
        if (bold)      def.bold      = true
        if (italic)    def.italic    = true
        if (underline) def.underline = true
        syntaxStyle.registerStyle(styleName, def)
      }

      result.push([token.offset, token.offset + token.content.length, styleName])
    }
  }

  return result
}

export function createShikiHighlightCallback(theme: ThemeName) {
  const shikiTheme = SHIKI_THEME_MAP[theme] ?? 'github-dark'

  return async function onHighlight(
    _highlights: [number, number, string, unknown?][],
    context: { content: string; filetype: string; syntaxStyle: SyntaxStyle },
  ): Promise<[number, number, string][] | undefined> {
    const lang = context.filetype.toLowerCase()
    if (!lang) return undefined

    const hl = await getHighlighter()

    let tokenResult: { tokens: { content: string; offset: number; color?: string; fontStyle?: number }[][] }
    try {
      tokenResult = hl.codeToTokens(context.content, { theme: shikiTheme, lang: lang as any })
    } catch {
      return undefined
    }

    return buildHighlights(tokenResult, context.syntaxStyle)
  }
}

// One-shot highlight for use outside of CodeRenderable (e.g. static code blocks)
export async function highlightCode(
  code: string,
  lang: string,
  syntaxStyle: SyntaxStyle,
  theme: ThemeName,
): Promise<[number, number, string][] | undefined> {
  const shikiTheme = SHIKI_THEME_MAP[theme] ?? 'github-dark'
  const hl = await getHighlighter()

  let tokenResult: { tokens: { content: string; offset: number; color?: string; fontStyle?: number }[][] }
  try {
    tokenResult = hl.codeToTokens(code, { theme: shikiTheme, lang: lang as any })
  } catch {
    return undefined
  }

  return buildHighlights(tokenResult, syntaxStyle)
}
