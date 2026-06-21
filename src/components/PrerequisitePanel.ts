import { BoxRenderable, TextRenderable, createTextAttributes, type RenderContext } from '@opentui/core'
import type { PrerequisiteResult } from '../engine/Prerequisites.js'
import { DANGER, WARNING } from '../theme/colors.js'

export function createPrerequisitePanel(ctx: RenderContext, result: PrerequisiteResult): BoxRenderable {
  const panel = new BoxRenderable(ctx, {
    flexDirection: 'column',
    flexShrink: 0,
    border: true,
    borderColor: DANGER,
    marginBottom: 1,
  })

  panel.add(new TextRenderable(ctx, {
    content: '  Prerequisites failed — code fence execution is disabled',
    fg: DANGER,
    attributes: createTextAttributes({ bold: true }),
    flexShrink: 0,
  }))

  for (const msg of result.failed) {
    panel.add(new TextRenderable(ctx, {
      content: `  ✗ ${msg}`,
      fg: WARNING,
      flexShrink: 0,
    }))
  }

  return panel
}
