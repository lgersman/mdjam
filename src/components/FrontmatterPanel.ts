import {
  BoxRenderable,
  TextRenderable,
  InputRenderable,
  type RenderContext,
} from '@opentui/core'
import { InputRow } from './InputRow.js'
import type { StateStore } from '../engine/StateStore.js'

export class FrontmatterPanel extends BoxRenderable {
  private rows: InputRow[] = []

  constructor(
    ctx: RenderContext,
    defaults: Record<string, string>,
    stateStore: StateStore,
  ) {
    super(ctx, {
      flexDirection: 'column',
      flexShrink: 0,
      marginBottom: 1,
      border: true,
      borderColor: '#30363d',
    })

    this.add(new TextRenderable(ctx, {
      content: '  Variables',
      fg: '#8b949e',
      italic: true,
      flexShrink: 0,
    } as any))

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
