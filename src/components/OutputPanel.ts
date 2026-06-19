import { ScrollBoxRenderable, TextRenderable, type RenderContext } from '@opentui/core'
import type { ScrollBoxOptions } from '@opentui/core'

const MAX_LINES = 10_000
const SCROLL_THRESHOLD = 7

export class OutputPanel extends ScrollBoxRenderable {
  private readonly renderCtx: RenderContext
  private lineCount = 0
  private truncated = false

  constructor(ctx: RenderContext, options: ScrollBoxOptions = {}) {
    super(ctx, {
      flexShrink: 0,
      scrollY: true,
      scrollX: false,
      stickyScroll: true,
      stickyStart: 'bottom',
      contentOptions: {
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
        this.maxHeight = SCROLL_THRESHOLD
        return
      }

      const lineNode = new TextRenderable(this.renderCtx, {
        content: line,
        flexShrink: 0,
      })
      lineNode.selectable = true
      this.add(lineNode)
    }

    if (lines.length > 0) {
      this.maxHeight = Math.min(this.lineCount, SCROLL_THRESHOLD)
      this.visible = true
    }
  }

  get isScrollable(): boolean {
    return this.lineCount > SCROLL_THRESHOLD
  }

  clear(): void {
    const children = [...this.getChildren()]
    for (const child of children) {
      this.remove(child.id)
    }
    this.lineCount = 0
    this.truncated = false
    this.maxHeight = undefined
    this.visible = false
  }

}
