import { BoxRenderable, type RenderContext } from '@opentui/core'
import { InputRow } from './InputRow.js'
import type { FenceMetadata } from '../parser/metadata.js'
import type { StateStore } from '../engine/StateStore.js'

export class InputPanel extends BoxRenderable {
  private rows: InputRow[] = []

  constructor(ctx: RenderContext, metadata: FenceMetadata, stateStore: StateStore) {
    super(ctx, {
      flexDirection: 'column',
      flexShrink: 0,
      marginBottom: 0,
    })

    if (!metadata.inputs) return

    for (const [name, spec] of Object.entries(metadata.inputs)) {
      const row = new InputRow(ctx, { name, spec, stateStore })
      this.rows.push(row)
      this.add(row)
    }
  }

  /** Returns true if all required inputs (no default, not set) have a value. */
  allInputsSatisfied(): boolean {
    return this.rows.every(row => row.hasValue())
  }

  /** Returns names of inputs that have no value. */
  missingInputs(): string[] {
    return this.rows.filter(r => !r.hasValue()).map(r => r.name)
  }


}
