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

export class CodeFenceRenderable extends BoxRenderable {
  private inputPanel: InputPanel | null = null
  private outputPanel: OutputPanel
  private readonly _runner: BlockRunner
  private readonly options: CodeFenceOptions

  constructor(ctx: RenderContext, opts: CodeFenceOptions) {
    super(ctx, {
      flexDirection: 'column',
      flexShrink: 0,
      marginBottom: 1,
      border: true,
      borderColor: BORDER_DEFAULT,
      focusedBorderColor: ACCENT,
      focusable: true,
    })

    this._runner = opts.runner
    this.options = opts

    // Header: description or parseError
    if (opts.parseError) {
      this.add(new TextRenderable(ctx, {
        content: `⚠ Metadata parse error: ${opts.parseError}`,
        fg: DANGER,
        flexShrink: 0,
        paddingLeft: 1,
      }))
    } else if (opts.metadata?.description) {
      this.add(new TextRenderable(ctx, {
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
        this.outputPanel.clear()
        opts.onExecute().catch(() => {})
      })
      this.add(this.inputPanel)
    }

    // Fence body: syntax-highlighted code
    this.add(new CodeRenderable(ctx, {
      content: opts.cleanBody.trimEnd(),
      filetype: 'bash',
      syntaxStyle: opts.syntaxStyle,
      conceal: false,
      flexShrink: 0,
      paddingLeft: 2,
    }))

    // Output panel (hidden until execution)
    this.outputPanel = new OutputPanel(ctx)
    this.add(this.outputPanel)

    // Wire up runner output
    this._runner.on('output', (text: string) => {
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

      this.outputPanel.clear()
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
    if (hasFocus) {
      this.borderColor = ACCENT
    } else {
      this.borderColor = BORDER_DEFAULT
    }
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
