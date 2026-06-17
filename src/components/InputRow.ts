import {
  BoxRenderable,
  TextRenderable,
  InputRenderable,
  InputRenderableEvents,
  type RenderContext,
} from '@opentui/core'
import type { InputSpec } from '../parser/metadata.js'
import type { StateStore } from '../engine/StateStore.js'

export interface InputRowOptions {
  name: string
  spec: InputSpec
  stateStore: StateStore
}

export class InputRow extends BoxRenderable {
  readonly name: string
  private valueInput: InputRenderable | null = null
  private valueDisplay: TextRenderable | null = null
  private sourceLabel: TextRenderable
  private readonly spec: InputSpec
  private readonly stateStore: StateStore

  constructor(ctx: RenderContext, options: InputRowOptions) {
    super(ctx, {
      flexDirection: 'row',
      flexShrink: 0,
      paddingLeft: 2,
      marginBottom: 0,
    })

    this.name = options.name
    this.spec = options.spec
    this.stateStore = options.stateStore

    // Name label
    this.add(new TextRenderable(ctx, {
      content: `  ${options.name}: `,
      fg: '#8b949e',
      flexShrink: 0,
    }))

    // Value field or display
    const storeValue = this.stateStore.get(options.name)
    if (storeValue === undefined && options.spec.default !== undefined) {
      this.stateStore.set(options.name, options.spec.default, null)
    }
    const initial = storeValue ?? options.spec.default ?? ''
    const source = this.resolveSource(options.name)

    if (options.spec.readonly) {
      this.valueDisplay = new TextRenderable(ctx, {
        content: initial,
        fg: '#a5d6ff',
        flexGrow: 1,
      })
      this.add(this.valueDisplay)
    } else {
      this.valueInput = new InputRenderable(ctx, {
        value: initial,
        textColor: '#f0f0f0',
        flexGrow: 1,
      })
      this.valueInput.focusable = true
      this.valueInput.on(InputRenderableEvents.CHANGE, (value: string) => {
        this.stateStore.set(options.name, value, null)
      })
      this.valueInput.on(InputRenderableEvents.ENTER, () => {
        this.emit('submit')
      })
      this.add(this.valueInput)
    }

    this.sourceLabel = new TextRenderable(ctx, {
      content: source ? ` [${source}]` : '',
      fg: '#6e7781',
      flexShrink: 0,
    })
    this.add(this.sourceLabel)

    // Description tooltip (only if spec has one)
    if (options.spec.description) {
      const desc = new BoxRenderable(ctx, {
        flexDirection: 'row',
        paddingLeft: 4,
      })
      desc.add(new TextRenderable(ctx, {
        content: options.spec.description,
        fg: '#6e7781',
        italic: true,
      } as any))
      this.add(desc)
    }

    // Watch store for upstream changes to this key
    this.stateStore.on('change', (key: string, value: string, sourceBlock: string | null) => {
      if (key === options.name) {
        this.updateValue(value, sourceBlock ? `block:${sourceBlock}` : null)
      }
    })
  }

  get inputRenderable(): InputRenderable | null {
    return this.valueInput
  }

  get currentValue(): string {
    if (this.valueInput) return this.valueInput.value
    // TextRenderable.content returns StyledText (not string), so read from state store directly
    return this.stateStore.get(this.name) ?? this.spec.default ?? ''
  }

  hasValue(): boolean {
    return this.currentValue.length > 0
  }

  private updateValue(value: string, source: string | null): void {
    if (this.valueInput) {
      this.valueInput.value = value
    } else if (this.valueDisplay) {
      this.valueDisplay.content = value
    }
    this.sourceLabel.content = source ? ` [${source}]` : ''
  }

  private resolveSource(name: string): string | null {
    const entry = this.stateStore.getEntry(name)
    if (!entry) return null
    if (entry.sourceBlock === null) return null
    return `block:${entry.sourceBlock}`
  }
}
