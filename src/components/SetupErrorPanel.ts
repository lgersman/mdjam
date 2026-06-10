import { BoxRenderable, TextRenderable, type RenderContext } from '@opentui/core'

export class SetupErrorPanel extends BoxRenderable {
  private rendererCtx: RenderContext

  constructor(ctx: RenderContext, exitCode: number) {
    super(ctx, {
      flexDirection: 'column',
      flexShrink: 0,
      border: true,
      borderColor: '#f85149',
      marginBottom: 1,
    })

    this.rendererCtx = ctx

    this.add(new TextRenderable(ctx, {
      content: `  Setup script failed (exit ${exitCode}) — code fence execution is disabled`,
      fg: '#f85149',
      bold: true,
      flexShrink: 0,
    } as any))
  }

  appendOutput(text: string): void {
    this.add(new TextRenderable(this.rendererCtx, {
      content: `  ${text}`,
      fg: '#ffa657',
      flexShrink: 0,
    }))
  }
}
