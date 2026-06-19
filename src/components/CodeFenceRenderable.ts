import {
  BoxRenderable,
  TextRenderable,
  CodeRenderable,
  InputRenderable,
  createTextAttributes,
  type RenderContext,
  type KeyEvent,
} from '@opentui/core'
import { BORDER_DEFAULT, ACCENT, DANGER, FG_MUTED } from '../theme/colors.js'
import type { SyntaxStyle } from '@opentui/core'
import type { Tokens } from 'marked'
import { InputPanel } from './InputPanel.js'
import { OutputPanel } from './OutputPanel.js'
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

export class CodeFenceRenderable extends BoxRenderable {
  private inputPanel: InputPanel | null = null
  private codeSection: BoxRenderable
  private outputSection: BoxRenderable
  private outputPanel: OutputPanel
  private readonly _runner: BlockRunner
  private readonly options: CodeFenceOptions

  constructor(ctx: RenderContext, opts: CodeFenceOptions) {
    // Outer box is a borderless flex container; borders live on codeSection/outputSection
    super(ctx, {
      flexDirection: 'column',
      flexShrink: 0,
      marginBottom: 1,
      focusable: true,
    })

    this._runner = opts.runner
    this.options = opts

    // Code section — full border initially, bottom dropped when output is shown
    this.codeSection = new BoxRenderable(ctx, {
      flexDirection: 'column',
      flexShrink: 0,
      border: true,
      borderColor: BORDER_DEFAULT,
    })
    this.add(this.codeSection)

    // Header: description or parseError
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

    // Input panel (only if inputs declared)
    if (opts.metadata?.inputs && Object.keys(opts.metadata.inputs).length > 0) {
      this.inputPanel = new InputPanel(ctx, opts.metadata, opts.stateStore)
      this.inputPanel.on('submit', () => {
        if (opts.executionBlocked) return
        if (this.inputPanel && !this.inputPanel.allInputsSatisfied()) return
        if (this.runner.status === 'running') return
        this.clearOutput()
        opts.onExecute().catch(() => {})
      })
      this.codeSection.add(this.inputPanel)
    }

    // Fence body: syntax-highlighted code
    this.codeSection.add(new CodeRenderable(ctx, {
      content: opts.cleanBody.trimEnd(),
      filetype: 'bash',
      syntaxStyle: opts.syntaxStyle,
      conceal: false,
      flexShrink: 0,
      paddingLeft: 2,
    }))

    // Output section — hidden until execution, ├/┤ corners connect to codeSection borders
    this.outputSection = new BoxRenderable(ctx, {
      flexDirection: 'column',
      flexShrink: 0,
      border: true,
      borderColor: BORDER_DEFAULT,
      customBorderChars: OUTPUT_BORDER_CHARS,
    })
    this.outputSection.visible = false
    this.add(this.outputSection)

    this.outputPanel = new OutputPanel(ctx)
    this.outputSection.add(this.outputPanel)

    // Wire up runner output
    this._runner.on('output', (text: string) => {
      if (!this.outputSection.visible) {
        this.codeSection.border = ['top', 'left', 'right']
        this.outputSection.visible = true
      }
      this.outputPanel.append(text)
    })

    // Initial blocked state
    if (opts.executionBlocked || (this.inputPanel && !this.inputPanel.allInputsSatisfied())) {
      this._runner.status = 'blocked'
    }

    // Watch state store for input changes that may unblock this fence
    if (this.inputPanel) {
      opts.stateStore.on('change', () => {
        if (!opts.executionBlocked && this._runner.status === 'blocked') {
          if (this.inputPanel!.allInputsSatisfied()) {
            this._runner.status = 'idle'
            this._runner.emit('status', 'idle')
          }
        }
      })
    }
  }

  private clearOutput(): void {
    this.codeSection.border = true
    this.outputSection.visible = false
    this.outputPanel.clear()
    // Restore border colors after border reset
    const color = this._focused ? ACCENT : BORDER_DEFAULT
    this.codeSection.borderColor = color
    this.outputSection.borderColor = color
  }

  get hasScrollableOutput(): boolean {
    return this.outputPanel.isScrollable
  }

  scrollOutputBy(delta: number): void {
    this.outputPanel.scrollBy(delta)
  }

  scrollOutputTo(position: number | { x: number; y: number }): void {
    this.outputPanel.scrollTo(position)
  }

  get outputScrollHeight(): number {
    return this.outputPanel.scrollHeight
  }

  override handleKeyPress(key: KeyEvent): boolean {
    if (key.name === 'return' || key.name === 'enter') {
      if (this.options.executionBlocked) return true
      if (this.inputPanel && !this.inputPanel.allInputsSatisfied()) return true
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
    return this.inputPanel?.inputRenderables ?? []
  }

  get hasOnlyReadonlyInputs(): boolean {
    return this.inputPanel !== null && this.inputRenderables.length === 0
  }

  get missingInputs(): string[] {
    return this.inputPanel?.missingInputs() ?? []
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
