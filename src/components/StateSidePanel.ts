import { BoxRenderable, TextRenderable, type RenderContext } from '@opentui/core'
import type { StateStore } from '../engine/StateStore.js'
import { BG_BASE, BORDER_DEFAULT, FG_DEFAULT, FG_SUBTLE, ACCENT_SUBTLE } from '../theme/colors.js'

export class StateSidePanel extends BoxRenderable {
  private contentBox: BoxRenderable
  private stateStore: StateStore
  private readonly renderCtx: RenderContext

  constructor(ctx: RenderContext, stateStore: StateStore) {
    super(ctx, {
      position: 'absolute',
      right: 0,
      top: 0,
      width: 60,
      height: '100%',
      flexDirection: 'column',
      border: true,
      borderColor: BORDER_DEFAULT,
      backgroundColor: BG_BASE,
      zIndex: 100,
      visible: false,
    })

    this.stateStore = stateStore
    this.renderCtx = ctx

    this.add(new TextRenderable(ctx, {
      content: ' State Store  [s] to close',
      fg: FG_DEFAULT,
      bold: true,
      flexShrink: 0,
      paddingBottom: 1,
    } as any))

    this.contentBox = new BoxRenderable(ctx, {
      flexDirection: 'column',
      flexGrow: 1,
    })
    this.add(this.contentBox)

    stateStore.on('change', () => this.refresh())
    stateStore.on('reset', () => this.refresh())
  }

  setStore(store: StateStore): void {
    this.stateStore = store
    store.on('change', () => { if (this.visible) this.refresh() })
    store.on('reset', () => { if (this.visible) this.refresh() })
    if (this.visible) this.refresh()
  }

  toggle(): void {
    this.visible = !this.visible
    if (this.visible) this.refresh()
  }

  private refresh(): void {
    // Remove old content children
    for (const child of this.contentBox.getChildren()) {
      this.contentBox.remove(child.id)
    }

    if (this.stateStore.size() === 0) {
      this.contentBox.add(new TextRenderable(this.renderCtx, {
        content: '  (empty)',
        fg: FG_SUBTLE,
      }))
      return
    }

    for (const [key, entry] of this.stateStore.entries()) {
      const source = entry.sourceBlock === null ? 'setup' : `block:${entry.sourceBlock}`
      const row = new TextRenderable(this.renderCtx, {
        content: `  ${key} = ${entry.value}  [${source}]`,
        fg: ACCENT_SUBTLE,
        flexShrink: 0,
      })
      this.contentBox.add(row)
    }
  }
}
