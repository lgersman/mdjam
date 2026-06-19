import { BoxRenderable, TextRenderable, type RenderContext } from '@opentui/core'
import type { BlockStatus } from '../engine/BlockRunner.js'
import { BG_SURFACE, FG_MUTED, FG_SUBTLE, ACCENT, SUCCESS, RUNNING, DANGER } from '../theme/colors.js'

const STATUS_MAP: Record<BlockStatus, { fg: string; label: string }> = {
  idle:         { fg: FG_MUTED,  label: '' },
  running:      { fg: RUNNING,   label: 'Running…' },
  success:      { fg: SUCCESS,   label: 'Done' },
  failed:       { fg: DANGER,    label: 'Failed' },
  cancelled:    { fg: FG_MUTED,  label: 'Cancelled' },
  blocked:      { fg: FG_MUTED,  label: 'Blocked' },
  'dep-failed': { fg: DANGER,    label: 'Skipped — dep failed' },
}

export type BarContext = 'markdown' | 'fm-input' | 'block-input' | 'codeblock'

export class BottomStatusBar extends BoxRenderable {
  private leftText: TextRenderable
  private rightText: TextRenderable
  private context: BarContext = 'markdown'
  private blockStatus: BlockStatus = 'idle'
  private exitCode: number | null = null
  private missingList: string[] = []
  private flashTimer: ReturnType<typeof setTimeout> | null = null

  constructor(ctx: RenderContext) {
    super(ctx, {
      flexDirection: 'row',
      flexShrink: 0,
      width: '100%',
      backgroundColor: BG_SURFACE,
      paddingLeft: 1,
      paddingRight: 1,
    })

    this.leftText = new TextRenderable(ctx, {
      content: '',
      fg: FG_MUTED,
      flexGrow: 1,
    })
    this.add(this.leftText)

    this.rightText = new TextRenderable(ctx, {
      content: '[Tab] Next  [j/k] Scroll  [h] Help  [r] Reload  [s] State  [Ctrl+C] Quit',
      fg: FG_SUBTLE,
      flexShrink: 0,
    })
    this.add(this.rightText)
  }

  flash(message: string, durationMs = 2000): void {
    if (this.flashTimer) clearTimeout(this.flashTimer)
    this.leftText.content = message
    ;(this.leftText as any).fg = SUCCESS
    this.flashTimer = setTimeout(() => {
      this.flashTimer = null
      this.refresh()
    }, durationMs)
  }

  setContext(context: BarContext): void {
    this.context = context
    this.refresh()
  }

  updateBlockStatus(status: BlockStatus, exitCode?: number | null, missing?: string[]): void {
    this.blockStatus = status
    this.exitCode = exitCode ?? null
    this.missingList = missing ?? []
    this.refresh()
  }

  private refresh(): void {
    if (this.context === 'markdown') {
      this.leftText.content = ''
      ;(this.leftText as any).fg = FG_MUTED
      this.rightText.content = '[Tab] Next  [j/k] Scroll  [h] Help  [r] Reload  [s] State  [Ctrl+C] Quit'
      return
    }

    if (this.context === 'fm-input') {
      this.leftText.content = ''
      ;(this.leftText as any).fg = FG_MUTED
      this.rightText.content = '[Enter] Confirm  [Esc] Blur  [Tab] Next  [h] Help'
      return
    }

    // codeblock and block-input both show block status on left
    const info = STATUS_MAP[this.blockStatus]
    let label = info.label
    if (this.blockStatus === 'success' && this.exitCode !== null) {
      label = `Done (exit ${this.exitCode})`
    } else if (this.blockStatus === 'failed' && this.exitCode !== null) {
      label = `Failed (exit ${this.exitCode})`
    } else if (this.blockStatus === 'blocked' && this.missingList.length > 0) {
      label = `Blocked — missing: ${this.missingList.join(', ')}`
    }
    this.leftText.content = label
    ;(this.leftText as any).fg = info.fg

    if (this.context === 'block-input') {
      this.rightText.content = this.blockStatus === 'running'
        ? '[Esc] Blur  [h] Help'
        : '[Enter] Submit & Run  [Esc] Blur  [Tab] Next  [h] Help'
      return
    }

    // context === 'codeblock'
    if (this.blockStatus === 'running') {
      this.rightText.content = '[Esc] Cancel  [h] Help'
    } else if (this.blockStatus === 'blocked' || this.blockStatus === 'dep-failed') {
      this.rightText.content = '[Tab] Next  [Esc] Blur  [h] Help'
    } else {
      this.rightText.content = '[Enter] Run  [Esc] Blur  [Tab] Next  [j/k] Scroll  [h] Help'
    }
  }
}
