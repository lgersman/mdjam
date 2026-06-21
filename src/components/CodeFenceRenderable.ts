import {
  BoxRenderable,
  TextRenderable,
  CodeRenderable,
  InputRenderable,
  ScrollBoxRenderable,
  createTextAttributes,
  type RenderContext,
  type KeyEvent,
} from '@opentui/core'
import { BORDER_DEFAULT, ACCENT, DANGER, FG_MUTED } from '../theme/colors.js'
import type { SyntaxStyle } from '@opentui/core'
import type { Tokens } from 'marked'
import { InputRow } from './InputRow.js'
import type { FenceMetadata } from '../parser/metadata.js'
import type { BlockRunner } from '../engine/BlockRunner.js'
import type { StateStore } from '../engine/StateStore.js'

export interface CodeFenceOptions {
  token: Tokens.Code
  cleanBody: string
  metadata: FenceMetadata | null
  parseError?: string
  runner: BlockRunner
  stateStore: StateStore
  syntaxStyle: SyntaxStyle
  executionBlocked: boolean
  onExecute: () => Promise<void>
}

// Output section top border uses ├ and ┤ to visually connect with codeSection's left/right borders
const OUTPUT_BORDER_CHARS = {
  topLeft: '├', topRight: '┤', horizontal: '─', vertical: '│',
  topT: '┬', bottomT: '┴', leftT: '├', rightT: '┤', bottomLeft: '└', bottomRight: '┘', cross: '┼',
}

const MAX_OUTPUT_LINES = 10_000
const SCROLL_THRESHOLD = 7

export class CodeFenceRenderable extends BoxRenderable {
  private readonly renderCtx: RenderContext
  private inputRows: InputRow[] = []
  private codeSection: BoxRenderable
  private outputSection: BoxRenderable
  private outputScroll: ScrollBoxRenderable
  private outputLineCount = 0
  private outputTruncated = false
  private readonly _runner: BlockRunner
  private readonly options: CodeFenceOptions
  private _childFocused = false

  constructor(ctx: RenderContext, opts: CodeFenceOptions) {
    super(ctx, {
      flexDirection: 'column',
      flexShrink: 0,
      marginBottom: 1,
      focusable: true,
    })

    this.renderCtx = ctx
    this._runner = opts.runner
    this.options = opts

    this.codeSection = new BoxRenderable(ctx, {
      flexDirection: 'column',
      flexShrink: 0,
      border: true,
      borderColor: BORDER_DEFAULT,
    })
    this.add(this.codeSection)

    if (opts.parseError) {
      this.codeSection.add(new TextRenderable(ctx, {
        content: `⚠ Metadata parse error: ${opts.parseError}`,
        fg: DANGER,
        flexShrink: 0,
        paddingLeft: 1,
      }))
    } else if (opts.metadata?.description) {
      this.codeSection.add(new TextRenderable(ctx, {
        content: opts.metadata.description,
        fg: FG_MUTED,
        attributes: createTextAttributes({ italic: true }),
        flexShrink: 0,
      }))
    }

    // Inline InputPanel: rows added directly to codeSection
    if (opts.metadata?.inputs && Object.keys(opts.metadata.inputs).length > 0) {
      for (const [name, spec] of Object.entries(opts.metadata.inputs)) {
        const row = new InputRow(ctx, { name, spec, stateStore: opts.stateStore })
        row.on('submit', () => {
          if (opts.executionBlocked) return
          if (!this.allInputsSatisfied()) return
          if (this._runner.status === 'running') return
          this.clearOutput()
          opts.onExecute().catch(() => {})
        })
        this.inputRows.push(row)
        this.codeSection.add(row)
      }
    }

    this.codeSection.add(new CodeRenderable(ctx, {
      content: opts.cleanBody.trimEnd(),
      filetype: 'bash',
      syntaxStyle: opts.syntaxStyle,
      conceal: false,
      flexShrink: 0,
      paddingLeft: 2,
    }))

    // Inline OutputPanel: ScrollBoxRenderable + line-tracking state
    this.outputSection = new BoxRenderable(ctx, {
      flexDirection: 'column',
      flexShrink: 0,
      border: true,
      borderColor: BORDER_DEFAULT,
      customBorderChars: OUTPUT_BORDER_CHARS,
    })
    this.outputSection.visible = false
    this.add(this.outputSection)

    this.outputScroll = new ScrollBoxRenderable(ctx, {
      flexShrink: 0,
      scrollY: true,
      scrollX: false,
      stickyScroll: true,
      stickyStart: 'bottom',
      contentOptions: { flexDirection: 'column' },
    })
    this.outputScroll.visible = false
    this.outputSection.add(this.outputScroll)

    this._runner.on('output', (text: string) => {
      if (!this.outputSection.visible) {
        this.codeSection.border = ['top', 'left', 'right']
        this.outputSection.visible = true
      }
      this.appendOutputText(text)
    })

    if (opts.executionBlocked || (this.inputRows.length > 0 && !this.allInputsSatisfied())) {
      this._runner.status = 'blocked'
    }

    if (this.inputRows.length > 0) {
      opts.stateStore.on('change', () => {
        if (!opts.executionBlocked && this._runner.status === 'blocked') {
          if (this.allInputsSatisfied()) {
            this._runner.status = 'idle'
            this._runner.emit('status', 'idle')
          }
        }
      })
    }
  }

  private appendOutputText(text: string): void {
    if (this.outputTruncated) return

    const lines = text.split('\n').filter(l => l.length > 0)
    for (const line of lines) {
      this.outputLineCount++
      if (this.outputLineCount > MAX_OUTPUT_LINES) {
        this.outputTruncated = true
        this.outputScroll.add(new TextRenderable(this.renderCtx, {
          content: `[output truncated at ${MAX_OUTPUT_LINES} lines]`,
          flexShrink: 0,
        }))
        this.outputScroll.maxHeight = SCROLL_THRESHOLD
        return
      }
      const lineNode = new TextRenderable(this.renderCtx, {
        content: line,
        flexShrink: 0,
      })
      lineNode.selectable = true
      this.outputScroll.add(lineNode)
    }

    if (lines.length > 0) {
      this.outputScroll.maxHeight = Math.min(this.outputLineCount, SCROLL_THRESHOLD)
      this.outputScroll.visible = true
    }
  }

  private allInputsSatisfied(): boolean {
    return this.inputRows.every(row => row.hasValue())
  }

  setChildFocused(focused: boolean): void {
    this._childFocused = focused
    const color = (this._focused || focused) ? ACCENT : BORDER_DEFAULT
    this.codeSection.borderColor = color
    this.outputSection.borderColor = color
  }

  private clearOutput(): void {
    this.codeSection.border = true
    this.outputSection.visible = false
    for (const child of [...this.outputScroll.getChildren()]) {
      this.outputScroll.remove(child.id)
    }
    this.outputLineCount = 0
    this.outputTruncated = false
    this.outputScroll.maxHeight = undefined
    this.outputScroll.visible = false
    const color = (this._focused || this._childFocused) ? ACCENT : BORDER_DEFAULT
    this.codeSection.borderColor = color
    this.outputSection.borderColor = color
  }

  get hasScrollableOutput(): boolean {
    return this.outputLineCount > SCROLL_THRESHOLD
  }

  scrollOutputBy(delta: number): void {
    this.outputScroll.scrollBy(delta)
  }

  scrollOutputTo(position: number | { x: number; y: number }): void {
    this.outputScroll.scrollTo(position)
  }

  get outputScrollHeight(): number {
    return this.outputScroll.scrollHeight
  }

  override handleKeyPress(key: KeyEvent): boolean {
    if (key.name === 'return' || key.name === 'enter') {
      if (this.options.executionBlocked) return true
      if (!this.allInputsSatisfied()) return true
      if (this._runner.status === 'running') return true

      this.clearOutput()
      this.options.onExecute().catch(() => {})
      return true
    }

    if (key.name === 'escape') {
      if (this._runner.status === 'running') {
        this._runner.cancel()
      }
      return true
    }

    return false
  }

  protected override propagateFocusChange(hasFocus: boolean): void {
    super.propagateFocusChange(hasFocus)
    const color = hasFocus ? ACCENT : BORDER_DEFAULT
    this.codeSection.borderColor = color
    this.outputSection.borderColor = color
  }

  get inputRenderables(): InputRenderable[] {
    return this.inputRows.map(r => r.inputRenderable).filter((r): r is InputRenderable => r !== null)
  }

  get hasOnlyReadonlyInputs(): boolean {
    return this.inputRows.length > 0 && this.inputRenderables.length === 0
  }

  get missingInputs(): string[] {
    return this.inputRows.filter(r => !r.hasValue()).map(r => r.name)
  }

  get runner(): BlockRunner {
    return this._runner
  }

  get blockId(): string {
    return this._runner.blockId
  }

  get isAutoExecute(): boolean {
    return this.options.metadata?.auto === true
  }

  get isInteractive(): boolean {
    return this.options.metadata?.interactive === true
  }

  get isExecutionBlocked(): boolean {
    return this.options.executionBlocked
  }
}
