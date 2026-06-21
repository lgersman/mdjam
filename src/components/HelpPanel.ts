import { BoxRenderable, TextRenderable, TextTableRenderable, fg, createTextAttributes, type RenderContext } from '@opentui/core'
import { BG_BASE, ACCENT, FG_DEFAULT, ATTENTION } from '../theme/colors.js'

const HOTKEYS: { key: string; description: string }[] = [
  { key: '?',             description: 'Show / hide this help' },
  { key: 'Tab',           description: 'Focus next code block' },
  { key: 'Shift+Tab',     description: 'Focus previous code block' },
  { key: 'Enter',         description: 'Run focused code block' },
  { key: 'Escape',        description: 'Cancel running code block' },
  { key: 's',             description: 'Toggle state store panel' },
  { key: 'r',             description: 'Reload document' },
  { key: 'j / down',      description: 'Scroll down' },
  { key: 'k / up',        description: 'Scroll up' },
  { key: 'Space / PgDn',  description: 'Page down' },
  { key: 'b / PgUp',      description: 'Page up' },
  { key: 'g',             description: 'Scroll to top' },
  { key: 'G',             description: 'Scroll to bottom' },
  { key: 'Ctrl+Shift+C',  description: 'Copy selected text to clipboard' },
  { key: 'Ctrl+Shift+V',  description: 'Paste into focused input' },
  { key: 'Ctrl+C',        description: 'Quit' },
]

export class HelpPanel extends BoxRenderable {
  constructor(ctx: RenderContext) {
    super(ctx, {
      position: 'absolute',
      top: 2,
      left: '20%',
      width: '60%',
      flexDirection: 'column',
      border: true,
      borderColor: ACCENT,
      backgroundColor: BG_BASE,
      zIndex: 200,
      visible: false,
      paddingBottom: 1,
    })

    this.add(new TextRenderable(ctx, {
      content: '  Keyboard shortcuts  [?] or [Esc] to close',
      fg: ACCENT,
      attributes: createTextAttributes({ bold: true }),
      flexShrink: 0,
      paddingTop: 1,
      paddingBottom: 1,
    } as any))

    const tableContent = HOTKEYS.map(({ key, description }) => [
      [fg(ATTENTION)(key)],
      [fg(FG_DEFAULT)(description)],
    ])

    this.add(new TextTableRenderable(ctx, {
      content: tableContent,
      wrapMode: 'none',
      columnWidthMode: 'content',
      showBorders: false,
      border: false,
      outerBorder: false,
      backgroundColor: BG_BASE,
      cellPaddingX: 2,
      flexShrink: 0,
    } as any))
  }

  toggle(): void {
    this.visible = !this.visible
  }
}
