import { SyntaxStyle } from '@opentui/core'

export type ThemeName = 'dark' | 'light' | 'dracula' | 'tokyo-night'

// ANSI 256 → hex helpers (pre-computed for glamour's palette)
// Colors sourced from github.com/charmbracelet/glamour styles/*.json

const DARK = {
  // tree-sitter syntax tokens (mapped from glamour dark chroma)
  keyword:          { fg: '#00aaff' },
  string:           { fg: '#c69669' },
  number:           { fg: '#6eefc0' },
  comment:          { fg: '#676767', italic: true },
  function:         { fg: '#00d787' },
  variable:         { fg: '#c4c4c4' },
  type:             { fg: '#6e6ed8' },
  operator:         { fg: '#ef8080' },
  punctuation:      { fg: '#e8e8a8' },
  constant:         { fg: '#c4c4c4' },
  property:         { fg: '#7a7ae6' },
  tag:              { fg: '#b083ea' },
  attribute:        { fg: '#7a7ae6' },
  'string.special': { fg: '#afffd7' },
  plain:            { fg: '#c4c4c4' },
  conceal:          { fg: '#676767' },
  // markdown structural styles (mapped from glamour dark.json)
  default:                { fg: '#d0d0d0' },
  'markup.heading':       { fg: '#00afff', bold: true },
  'markup.strong':        { fg: '#d0d0d0', bold: true },
  'markup.italic':        { fg: '#d0d0d0', italic: true },
  'markup.strikethrough': { fg: '#808080' },
  'markup.raw':           { fg: '#ff5f5f' },
  'markup.link':          { fg: '#008787' },
  'markup.link.label':    { fg: '#00af5f', bold: true },
  'markup.link.url':      { fg: '#008787' },
}

const LIGHT = {
  // tree-sitter syntax tokens (mapped from glamour light chroma)
  keyword:          { fg: '#279efc' },
  string:           { fg: '#7e5b38' },
  number:           { fg: '#22ccae' },
  comment:          { fg: '#8d8d8d', italic: true },
  function:         { fg: '#019f57' },
  variable:         { fg: '#2a2a2a' },
  type:             { fg: '#7049c2' },
  operator:         { fg: '#ff2626' },
  punctuation:      { fg: '#fa7878' },
  constant:         { fg: '#581290' },
  property:         { fg: '#8362cb' },
  tag:              { fg: '#581290' },
  attribute:        { fg: '#8362cb' },
  'string.special': { fg: '#00aeae' },
  plain:            { fg: '#2a2a2a' },
  conceal:          { fg: '#8d8d8d' },
  // markdown structural styles (mapped from glamour light.json)
  default:                { fg: '#1c1c1c' },
  'markup.heading':       { fg: '#005fff', bold: true },
  'markup.strong':        { fg: '#1c1c1c', bold: true },
  'markup.italic':        { fg: '#1c1c1c', italic: true },
  'markup.strikethrough': { fg: '#8d8d8d' },
  'markup.raw':           { fg: '#ff5f5f' },
  'markup.link':          { fg: '#00af87' },
  'markup.link.label':    { fg: '#00875f', bold: true },
  'markup.link.url':      { fg: '#00af87' },
}

const DRACULA = {
  // tree-sitter syntax tokens (mapped from glamour dracula chroma)
  keyword:          { fg: '#ff79c6' },
  string:           { fg: '#f1fa8c' },
  number:           { fg: '#6eefc0' },
  comment:          { fg: '#6272a4', italic: true },
  function:         { fg: '#50fa7b' },
  variable:         { fg: '#8be9fd' },
  type:             { fg: '#8be9fd' },
  operator:         { fg: '#ff79c6' },
  punctuation:      { fg: '#f8f8f2' },
  constant:         { fg: '#bd93f9' },
  property:         { fg: '#50fa7b' },
  tag:              { fg: '#ff79c6' },
  attribute:        { fg: '#50fa7b' },
  'string.special': { fg: '#ff79c6' },
  plain:            { fg: '#f8f8f2' },
  conceal:          { fg: '#6272a4' },
  // markdown structural styles (mapped from glamour dracula.json)
  default:                { fg: '#f8f8f2' },
  'markup.heading':       { fg: '#bd93f9', bold: true },
  'markup.strong':        { fg: '#ffb86c', bold: true },
  'markup.italic':        { fg: '#f1fa8c', italic: true },
  'markup.strikethrough': { fg: '#6272a4' },
  'markup.raw':           { fg: '#50fa7b' },
  'markup.link':          { fg: '#8be9fd', underline: true },
  'markup.link.label':    { fg: '#ff79c6' },
  'markup.link.url':      { fg: '#8be9fd' },
}

const TOKYO_NIGHT = {
  // tree-sitter syntax tokens (mapped from glamour tokyo-night chroma)
  keyword:          { fg: '#2ac3de' },
  string:           { fg: '#e0af68' },
  number:           { fg: '#a9b1d6' },
  comment:          { fg: '#565f89', italic: true },
  function:         { fg: '#9ece6a' },
  variable:         { fg: '#7aa2f7' },
  type:             { fg: '#7aa2f7' },
  operator:         { fg: '#2ac3de' },
  punctuation:      { fg: '#a9b1d6' },
  constant:         { fg: '#bb9af7' },
  property:         { fg: '#9ece6a' },
  tag:              { fg: '#2ac3de' },
  attribute:        { fg: '#9ece6a' },
  'string.special': { fg: '#2ac3de' },
  plain:            { fg: '#a9b1d6' },
  conceal:          { fg: '#565f89' },
  // markdown structural styles (mapped from glamour tokyo-night.json)
  default:                { fg: '#a9b1d6' },
  'markup.heading':       { fg: '#bb9af7', bold: true },
  'markup.strong':        { fg: '#a9b1d6', bold: true },
  'markup.italic':        { fg: '#a9b1d6', italic: true },
  'markup.strikethrough': { fg: '#565f89' },
  'markup.raw':           { fg: '#9ece6a' },
  'markup.link':          { fg: '#7aa2f7', underline: true },
  'markup.link.label':    { fg: '#2ac3de' },
  'markup.link.url':      { fg: '#7aa2f7' },
}

const THEMES: Record<ThemeName, Record<string, { fg?: string; bold?: boolean; italic?: boolean; underline?: boolean }>> = {
  dark:          DARK,
  light:         LIGHT,
  dracula:       DRACULA,
  'tokyo-night': TOKYO_NIGHT,
}

export function createSyntaxStyle(theme: ThemeName): SyntaxStyle {
  const styles = THEMES[theme] ?? DARK
  return SyntaxStyle.fromStyles(styles)
}
