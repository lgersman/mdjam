import { BoxRenderable, TextRenderable, TextTableRenderable, fg, type RenderContext } from '@opentui/core'

const HOTKEYS: { key: string; description: string }[] = [
  { key: 'h',             description: 'Show / hide this help' },
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
      borderColor: '#58a6ff',
      backgroundColor: '#0d1117',
      zIndex: 200,
      visible: false,
      paddingBottom: 1,
    })

    this.add(new TextRenderable(ctx, {
      content: '  Keyboard shortcuts  [h] or [Esc] to close',
      fg: '#58a6ff',
      bold: true,
      flexShrink: 0,
      paddingTop: 1,
      paddingBottom: 1,
    } as any))

    const tableContent = HOTKEYS.map(({ key, description }) => [
      [fg('#e3b341')(key)],
      [fg('#c9d1d9')(description)],
    ])

    this.add(new TextTableRenderable(ctx, {
      content: tableContent,
      wrapMode: 'none',
      columnWidthMode: 'content',
      showBorders: false,
      border: false,
      outerBorder: false,
      backgroundColor: '#0d1117',
      cellPaddingX: 2,
      flexShrink: 0,
    } as any))
  }

  toggle(): void {
    this.visible = !this.visible
  }
}
