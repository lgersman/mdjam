import { BoxRenderable, TextRenderable, type RenderContext } from '@opentui/core'
import { BORDER_DEFAULT, FG_MUTED, FG_DEFAULT } from '../theme/colors.js'

export class TeardownPanel extends BoxRenderable {
  private readonly renderCtx: RenderContext

  constructor(ctx: RenderContext) {
    super(ctx, {
      flexDirection: 'column',
      flexShrink: 0,
      border: true,
      borderColor: BORDER_DEFAULT,
      visible: false,
    })

    this.renderCtx = ctx

    this.add(new TextRenderable(ctx, {
      content: '  Teardown',
      fg: FG_MUTED,
      flexShrink: 0,
    }))
  }

  appendOutput(text: string): void {
    this.add(new TextRenderable(this.renderCtx, {
      content: `  ${text}`,
      fg: FG_DEFAULT,
      flexShrink: 0,
    }))
    this.visible = true
  }
}
