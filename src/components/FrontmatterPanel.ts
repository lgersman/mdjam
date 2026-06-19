import {
  BoxRenderable,
  TextRenderable,
  InputRenderable,
  createTextAttributes,
  type RenderContext,
} from '@opentui/core'
import { InputRow } from './InputRow.js'
import type { StateStore } from '../engine/StateStore.js'
import { BORDER_DEFAULT, ACCENT, FG_MUTED } from '../theme/colors.js'

export class FrontmatterPanel extends BoxRenderable {
  private rows: InputRow[] = []

  constructor(
    ctx: RenderContext,
    defaults: Record<string, string>,
    stateStore: StateStore,
    description?: string,
  ) {
    super(ctx, {
      flexDirection: 'column',
      flexShrink: 0,
      marginBottom: 1,
      border: true,
      borderColor: BORDER_DEFAULT,
      focusedBorderColor: ACCENT,
    })

    if (description) {
      this.add(new TextRenderable(ctx, {
        content: description,
        fg: FG_MUTED,
        attributes: createTextAttributes({ italic: true }),
        flexShrink: 0,
        paddingLeft: 1,
      }))
    }

    for (const [name, defaultValue] of Object.entries(defaults)) {
      const row = new InputRow(ctx, {
        name,
        spec: { default: defaultValue },
        stateStore,
      })
      this.rows.push(row)
      this.add(row)
    }
  }

  get inputRenderables(): InputRenderable[] {
    return this.rows
      .map(r => r.inputRenderable)
      .filter((r): r is InputRenderable => r !== null)
  }
}
