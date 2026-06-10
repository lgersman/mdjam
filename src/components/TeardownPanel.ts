import { BoxRenderable, TextRenderable, type RenderContext } from '@opentui/core'

export class TeardownPanel extends BoxRenderable {
  private readonly renderCtx: RenderContext

  constructor(ctx: RenderContext) {
    super(ctx, {
      flexDirection: 'column',
      flexShrink: 0,
      border: true,
      borderColor: '#30363d',
      visible: false,
    })

    this.renderCtx = ctx

    this.add(new TextRenderable(ctx, {
      content: '  Teardown',
      fg: '#8b949e',
      flexShrink: 0,
    }))
  }

  appendOutput(text: string): void {
    this.add(new TextRenderable(this.renderCtx, {
      content: `  ${text}`,
      fg: '#c9d1d9',
      flexShrink: 0,
    }))
    this.visible = true
  }
}
