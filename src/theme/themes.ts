import { SyntaxStyle } from '@opentui/core'

export type ThemeName = 'github-dark' | 'github-light' | 'dracula'

const GITHUB_DARK = {
  // tree-sitter syntax tokens
  keyword: { fg: '#ff7b72', bold: true },
  string: { fg: '#a5d6ff' },
  number: { fg: '#79c0ff' },
  comment: { fg: '#8b949e', italic: true },
  function: { fg: '#d2a8ff' },
  variable: { fg: '#ffa657' },
  type: { fg: '#79c0ff' },
  operator: { fg: '#ff7b72' },
  punctuation: { fg: '#c9d1d9' },
  constant: { fg: '#79c0ff' },
  property: { fg: '#ffa657' },
  tag: { fg: '#7ee787' },
  attribute: { fg: '#a5d6ff' },
  'string.special': { fg: '#a5d6ff' },
  plain: { fg: '#c9d1d9' },
  conceal: { fg: '#8b949e' },
  // markdown structural styles
  default: { fg: '#c9d1d9' },
  'markup.heading': { fg: '#58a6ff', bold: true },
  'markup.strong': { fg: '#c9d1d9', bold: true },
  'markup.italic': { fg: '#c9d1d9', italic: true },
  'markup.strikethrough': { fg: '#8b949e' },
  'markup.raw': { fg: '#ffa657' },
  'markup.link': { fg: '#8b949e' },
  'markup.link.label': { fg: '#58a6ff', underline: true },
  'markup.link.url': { fg: '#8b949e' },
}

const GITHUB_LIGHT = {
  // tree-sitter syntax tokens
  keyword: { fg: '#cf222e', bold: true },
  string: { fg: '#0a3069' },
  number: { fg: '#0550ae' },
  comment: { fg: '#6e7781', italic: true },
  function: { fg: '#8250df' },
  variable: { fg: '#953800' },
  type: { fg: '#0550ae' },
  operator: { fg: '#cf222e' },
  punctuation: { fg: '#24292f' },
  constant: { fg: '#0550ae' },
  property: { fg: '#953800' },
  tag: { fg: '#116329' },
  attribute: { fg: '#0a3069' },
  'string.special': { fg: '#0a3069' },
  plain: { fg: '#24292f' },
  conceal: { fg: '#6e7781' },
  // markdown structural styles
  default: { fg: '#24292f' },
  'markup.heading': { fg: '#0550ae', bold: true },
  'markup.strong': { fg: '#24292f', bold: true },
  'markup.italic': { fg: '#24292f', italic: true },
  'markup.strikethrough': { fg: '#6e7781' },
  'markup.raw': { fg: '#953800' },
  'markup.link': { fg: '#6e7781' },
  'markup.link.label': { fg: '#0969da', underline: true },
  'markup.link.url': { fg: '#6e7781' },
}

const DRACULA = {
  // tree-sitter syntax tokens
  keyword: { fg: '#ff79c6', bold: true },
  string: { fg: '#f1fa8c' },
  number: { fg: '#bd93f9' },
  comment: { fg: '#6272a4', italic: true },
  function: { fg: '#50fa7b' },
  variable: { fg: '#ffb86c' },
  type: { fg: '#8be9fd' },
  operator: { fg: '#ff79c6' },
  punctuation: { fg: '#f8f8f2' },
  constant: { fg: '#bd93f9' },
  property: { fg: '#ffb86c' },
  tag: { fg: '#50fa7b' },
  attribute: { fg: '#50fa7b' },
  'string.special': { fg: '#f1fa8c' },
  plain: { fg: '#f8f8f2' },
  conceal: { fg: '#6272a4' },
  // markdown structural styles
  default: { fg: '#f8f8f2' },
  'markup.heading': { fg: '#bd93f9', bold: true },
  'markup.strong': { fg: '#f8f8f2', bold: true },
  'markup.italic': { fg: '#f8f8f2', italic: true },
  'markup.strikethrough': { fg: '#6272a4' },
  'markup.raw': { fg: '#50fa7b' },
  'markup.link': { fg: '#6272a4' },
  'markup.link.label': { fg: '#8be9fd', underline: true },
  'markup.link.url': { fg: '#6272a4' },
}

const THEMES: Record<ThemeName, Record<string, { fg?: string; bold?: boolean; italic?: boolean }>> = {
  'github-dark': GITHUB_DARK,
  'github-light': GITHUB_LIGHT,
  dracula: DRACULA,
}

export function createSyntaxStyle(theme: ThemeName): SyntaxStyle {
  const styles = THEMES[theme] ?? GITHUB_DARK
  return SyntaxStyle.fromStyles(styles)
}
