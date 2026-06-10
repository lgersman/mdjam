import { BoxRenderable, TextRenderable, type RenderContext } from '@opentui/core'
import type { PrerequisiteResult } from '../engine/Prerequisites.js'

export class PrerequisitePanel extends BoxRenderable {
  constructor(ctx: RenderContext, result: PrerequisiteResult) {
    super(ctx, {
      flexDirection: 'column',
      flexShrink: 0,
      border: true,
      borderColor: '#f85149',
      marginBottom: 1,
    })

    this.add(new TextRenderable(ctx, {
      content: '  Prerequisites failed — code fence execution is disabled',
      fg: '#f85149',
      bold: true,
      flexShrink: 0,
    } as any))

    for (const msg of result.failed) {
      this.add(new TextRenderable(ctx, {
        content: `  ✗ ${msg}`,
        fg: '#ffa657',
        flexShrink: 0,
      }))
    }
  }
}
