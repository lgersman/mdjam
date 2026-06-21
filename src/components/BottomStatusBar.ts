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
  delegate = false

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
      content: '[Tab] Next  [j/k] Scroll  [?] Help  [r] Reload  [s] State  [Ctrl+C] Quit',
      fg: FG_SUBTLE,
      flexShrink: 0,
    })
    this.add(this.rightText)
  }

  protected override onLayoutResize(width: number, height: number): void {
    super.onLayoutResize(width, height)
    this.applyLayout()
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

  private computeTexts(): { leftContent: string; leftFg: string; rightContent: string } {
    if (this.context === 'markdown') {
      return {
        leftContent: '',
        leftFg: FG_MUTED,
        rightContent: '[Tab] Next  [j/k] Scroll  [?] Help  [r] Reload  [s] State  [Ctrl+C] Quit',
      }
    }

    if (this.context === 'fm-input') {
      return {
        leftContent: '',
        leftFg: FG_MUTED,
        rightContent: '[Enter] Confirm  [Esc] Blur  [Tab] Next  [?] Help',
      }
    }

    // codeblock and block-input both show block status on left
    const info = STATUS_MAP[this.blockStatus]
    let leftContent = info.label
    if (this.blockStatus === 'success' && this.exitCode !== null) {
      leftContent = `Done (exit ${this.exitCode})`
      if (this.delegate) leftContent += ' · Ctrl+C to return output'
    } else if (this.blockStatus === 'failed' && this.exitCode !== null) {
      leftContent = `Failed (exit ${this.exitCode})`
      if (this.delegate) leftContent += ' · Ctrl+C to return output'
    } else if (this.blockStatus === 'blocked' && this.missingList.length > 0) {
      leftContent = `Blocked — missing: ${this.missingList.join(', ')}`
    }

    let rightContent: string
    if (this.context === 'block-input') {
      rightContent = this.blockStatus === 'running'
        ? '[Esc] Blur  [?] Help'
        : '[Enter] Submit & Run  [Esc] Blur  [Tab] Next  [?] Help'
    } else if (this.blockStatus === 'running') {
      rightContent = '[Esc] Cancel  [?] Help'
    } else if (this.blockStatus === 'blocked' || this.blockStatus === 'dep-failed') {
      rightContent = '[Tab] Next  [Esc] Blur  [?] Help'
    } else {
      rightContent = '[Enter] Run  [Esc] Blur  [Tab] Next  [j/k] Scroll  [?] Help'
    }

    return { leftContent, leftFg: info.fg, rightContent }
  }

  private applyLayout(): void {
    const { leftContent, leftFg, rightContent } = this.computeTexts()

    this.leftText.content = leftContent
    ;(this.leftText as any).fg = leftFg
    this.rightText.content = rightContent

    // paddingLeft + paddingRight = 2; 1 gap between the two texts in row mode
    const availableWidth = this.width - 2
    const fitsInRow = availableWidth > 0 && leftContent.length + 1 + rightContent.length <= availableWidth

    if (fitsInRow) {
      this.flexDirection = 'row'
      this.leftText.flexGrow = 1
    } else {
      this.flexDirection = 'column'
      this.leftText.flexGrow = 0
    }
  }

  private refresh(): void {
    this.applyLayout()
  }
}
