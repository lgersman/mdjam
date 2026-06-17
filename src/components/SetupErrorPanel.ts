import { BoxRenderable, TextRenderable, type RenderContext } from '@opentui/core'
import { DANGER, WARNING } from '../theme/colors.js'

export class SetupErrorPanel extends BoxRenderable {
  private rendererCtx: RenderContext

  constructor(ctx: RenderContext, exitCode: number) {
    super(ctx, {
      flexDirection: 'column',
      flexShrink: 0,
      border: true,
      borderColor: DANGER,
      marginBottom: 1,
    })

    this.rendererCtx = ctx

    this.add(new TextRenderable(ctx, {
      content: `  Setup script failed (exit ${exitCode}) — code fence execution is disabled`,
      fg: DANGER,
      bold: true,
      flexShrink: 0,
    } as any))
  }

  appendOutput(text: string): void {
    this.add(new TextRenderable(this.rendererCtx, {
      content: `  ${text}`,
      fg: WARNING,
      flexShrink: 0,
    }))
  }
}
