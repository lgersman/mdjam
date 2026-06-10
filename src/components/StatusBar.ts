import { BoxRenderable, TextRenderable, type RenderContext } from '@opentui/core'
import type { BlockStatus } from '../engine/BlockRunner.js'

const STATUS_MAP: Record<BlockStatus, { icon: string; fg: string; label: string }> = {
  idle:       { icon: '○', fg: '#8b949e', label: 'Ready' },
  running:    { icon: '⟳', fg: '#f0a030', label: 'Running…' },
  success:    { icon: '✓', fg: '#3fb950', label: 'Done' },
  failed:     { icon: '✗', fg: '#f85149', label: 'Failed' },
  cancelled:  { icon: '◌', fg: '#8b949e', label: 'Cancelled' },
  blocked:    { icon: '✗', fg: '#f85149', label: 'Blocked' },
  'dep-failed': { icon: '✗', fg: '#f85149', label: 'Skipped — dep failed' },
}

export class StatusBar extends BoxRenderable {
  private statusText: TextRenderable
  private hintText: TextRenderable

  constructor(ctx: RenderContext) {
    super(ctx, {
      flexDirection: 'row',
      flexShrink: 0,
      paddingLeft: 2,
      paddingTop: 0,
      paddingBottom: 0,
    })

    this.statusText = new TextRenderable(ctx, {
      content: '○ Ready',
      fg: '#8b949e',
      flexGrow: 1,
    })
    this.add(this.statusText)

    this.hintText = new TextRenderable(ctx, {
      content: '  [Enter] Run',
      fg: '#6e7781',
      flexShrink: 0,
    })
    this.add(this.hintText)
  }

  update(status: BlockStatus, exitCode?: number | null, missing?: string[]): void {
    const info = STATUS_MAP[status]

    let label = info.label
    if (status === 'success' && exitCode !== undefined && exitCode !== null) {
      label = `Done (exit ${exitCode})`
    } else if (status === 'failed' && exitCode !== undefined && exitCode !== null) {
      label = `Failed (exit ${exitCode})`
    } else if (status === 'blocked' && missing?.length) {
      label = `Blocked — missing: ${missing.join(', ')}`
    }

    this.statusText.content = `${info.icon} ${label}`
    ;(this.statusText as any).fg = info.fg

    // Update hint based on state
    if (status === 'running') {
      this.hintText.content = '  [Esc] Cancel'
    } else if (status === 'blocked') {
      this.hintText.content = ''
    } else {
      this.hintText.content = '  [Enter] Run'
    }
  }

  setFocused(focused: boolean): void {
    // Highlight hint text when focused
    ;(this.hintText as any).fg = focused ? '#58a6ff' : '#6e7781'
  }
}
