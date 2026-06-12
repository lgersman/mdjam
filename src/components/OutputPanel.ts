import { ScrollBoxRenderable, TextRenderable, type RenderContext } from '@opentui/core'
import type { ScrollBoxOptions } from '@opentui/core'

const MAX_LINES = 10_000
const OUTPUT_MAX_HEIGHT = 10

export class OutputPanel extends ScrollBoxRenderable {
  private readonly renderCtx: RenderContext
  private lineCount = 0
  private truncated = false
  collapsed = false

  constructor(ctx: RenderContext, options: ScrollBoxOptions = {}) {
    super(ctx, {
      maxHeight: OUTPUT_MAX_HEIGHT,
      flexShrink: 0,
      scrollY: true,
      scrollX: false,
      stickyScroll: true,
      stickyStart: 'bottom',
      contentOptions: {
        paddingLeft: 2,
        flexDirection: 'column',
      },
      ...options,
    })

    this.renderCtx = ctx
    this.visible = false
  }

  append(text: string): void {
    if (this.truncated) return

    const lines = text.split('\n').filter(l => l.length > 0)

    for (const line of lines) {
      this.lineCount++

      if (this.lineCount > MAX_LINES) {
        this.truncated = true
        this.add(new TextRenderable(this.renderCtx, {
          content: `[output truncated at ${MAX_LINES} lines]`,
          flexShrink: 0,
        }))
        return
      }

      this.add(new TextRenderable(this.renderCtx, {
        content: line,
        flexShrink: 0,
      }))
    }

    if (lines.length > 0) {
      this.visible = true
    }
  }

  clear(): void {
    const children = [...this.getChildren()]
    for (const child of children) {
      this.remove(child.id)
    }
    this.lineCount = 0
    this.truncated = false
    this.visible = false
  }

  toggle(): void {
    this.collapsed = !this.collapsed
    if (!this.collapsed && this.lineCount > 0) {
      this.visible = true
    } else {
      this.visible = this.collapsed ? false : this.lineCount > 0
    }
  }
}
