import {
  BoxRenderable,
  TextRenderable,
  ScrollBoxRenderable,
  createTextAttributes,
  type RenderContext,
  type KeyEvent,
} from '@opentui/core'
import { BORDER_DEFAULT, ACCENT, FG_DEFAULT, FG_MUTED } from '../theme/colors.js'

export interface HeadingEntry {
  depth: number
  text: string
  id: string
}

export interface TocOptions {
  headings: HeadingEntry[]
  scrollBox: ScrollBoxRenderable
  title?: string
  minDepth?: number
  maxDepth?: number
}

export class TocRenderable extends BoxRenderable {
  private selectedIndex = 0
  private readonly entries: HeadingEntry[]
  private readonly entryRows: TextRenderable[]
  private readonly scrollBox: ScrollBoxRenderable

  constructor(ctx: RenderContext, opts: TocOptions) {
    super(ctx, {
      flexDirection: 'column',
      flexShrink: 0,
      marginBottom: 1,
      focusable: true,
      border: true,
      borderColor: BORDER_DEFAULT,
    })

    const minDepth = opts.minDepth ?? 1
    const maxDepth = opts.maxDepth ?? 6
    this.entries = opts.headings.filter(h => h.depth >= minDepth && h.depth <= maxDepth)
    this.scrollBox = opts.scrollBox
    this.entryRows = []

    if (opts.title) {
      this.add(new TextRenderable(ctx, {
        content: ` ${opts.title}`,
        fg: FG_MUTED,
        attributes: createTextAttributes({ bold: true }),
        flexShrink: 0,
      }))
    }

    for (const entry of this.entries) {
      const indent = '  '.repeat(entry.depth - minDepth)
      const bullet = entry.depth === minDepth ? '▸' : '·'
      const row = new TextRenderable(ctx, {
        content: `${indent}${bullet} ${entry.text}`,
        fg: FG_MUTED,
        flexShrink: 0,
        paddingLeft: 1,
      })
      this.entryRows.push(row)
      this.add(row)
    }

    if (this.entries.length > 0) {
      this.updateHighlight()
    }
  }

  private updateHighlight(): void {
    for (let i = 0; i < this.entryRows.length; i++) {
      if (i === this.selectedIndex) {
        this.entryRows[i].fg = FG_DEFAULT
        this.entryRows[i].attributes = createTextAttributes({ bold: true })
      } else {
        this.entryRows[i].fg = FG_MUTED
        this.entryRows[i].attributes = createTextAttributes({})
      }
    }
  }

  override handleKeyPress(key: KeyEvent): boolean {
    if (this.entries.length === 0) return false

    if (key.name === 'up' || key.name === 'k') {
      if (this.selectedIndex > 0) {
        this.selectedIndex--
        this.updateHighlight()
      }
      return true
    }

    if (key.name === 'down' || key.name === 'j') {
      if (this.selectedIndex < this.entries.length - 1) {
        this.selectedIndex++
        this.updateHighlight()
      }
      return true
    }

    if (key.name === 'return' || key.name === 'enter') {
      const entry = this.entries[this.selectedIndex]
      const child = this.scrollBox.content.findDescendantById(entry.id)
      this.scrollBox.scrollTo(child ? child.y : 0)
      return true
    }

    return false
  }

  protected override propagateFocusChange(hasFocus: boolean): void {
    super.propagateFocusChange(hasFocus)
    this.borderColor = hasFocus ? ACCENT : BORDER_DEFAULT
  }
}
