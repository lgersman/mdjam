import { BoxRenderable, TextRenderable, type RenderContext } from '@opentui/core'
import type { BoxOptions } from '@opentui/core'

const MAX_LINES = 10_000

export class OutputPanel extends BoxRenderable {
  private textRenderable: TextRenderable
  private lineCount = 0
  private truncated = false
  collapsed = false

  constructor(ctx: RenderContext, options: BoxOptions = {}) {
    super(ctx, {
      flexDirection: 'column',
      flexShrink: 0,
      paddingLeft: 2,
      ...options,
    })

    this.textRenderable = new TextRenderable(ctx, {
      content: '',
      flexShrink: 0,
    })
    this.add(this.textRenderable)
    this.visible = false
  }

  append(text: string): void {
    if (this.truncated) return

    const newLines = text.split('\n').length - 1
    this.lineCount += newLines

    if (this.lineCount > MAX_LINES) {
      this.truncated = true
      const current = typeof this.textRenderable.content === 'string'
        ? this.textRenderable.content
        : ''
      this.textRenderable.content = current + `\n[output truncated at ${MAX_LINES} lines]`
      return
    }

    const current = typeof this.textRenderable.content === 'string'
      ? this.textRenderable.content
      : ''
    this.textRenderable.content = current + text
    this.visible = true
  }

  clear(): void {
    this.textRenderable.content = ''
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
