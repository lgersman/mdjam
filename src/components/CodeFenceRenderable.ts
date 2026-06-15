import {
  BoxRenderable,
  TextRenderable,
  CodeRenderable,
  InputRenderable,
  type RenderContext,
  type KeyEvent,
} from '@opentui/core'
import type { SyntaxStyle } from '@opentui/core'
import type { Tokens } from 'marked'
import { InputPanel } from './InputPanel.js'
import { StatusBar } from './StatusBar.js'
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
  private statusBar: StatusBar
  private outputPanel: OutputPanel
  private readonly runner: BlockRunner
  private readonly options: CodeFenceOptions

  constructor(ctx: RenderContext, opts: CodeFenceOptions) {
    super(ctx, {
      flexDirection: 'column',
      flexShrink: 0,
      marginBottom: 1,
      border: true,
      borderColor: '#30363d',
      focusedBorderColor: '#58a6ff',
      focusable: true,
    })

    this.runner = opts.runner
    this.options = opts

    // Header: description or parseError
    if (opts.parseError) {
      this.add(new TextRenderable(ctx, {
        content: `⚠ Metadata parse error: ${opts.parseError}`,
        fg: '#f85149',
        flexShrink: 0,
        paddingLeft: 1,
      }))
    } else if (opts.metadata?.description) {
      this.add(new TextRenderable(ctx, {
        content: `  ${opts.metadata.description}`,
        fg: '#8b949e',
        italic: true,
        flexShrink: 0,
      } as any))
    }

    // Cycle indicator
    if (opts.metadata?.id && !opts.metadata.depends?.length) {
      // No cycle check needed if no deps
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

    // Status bar
    this.statusBar = new StatusBar(ctx)
    this.add(this.statusBar)

    // Output panel (hidden until execution)
    this.outputPanel = new OutputPanel(ctx)
    this.add(this.outputPanel)

    // Wire up runner events
    this.runner.on('status', (status, exitCode) => {
      const missing = this.inputPanel?.missingInputs()
      this.statusBar.update(status, exitCode, missing)
    })

    this.runner.on('output', (text: string) => {
      this.outputPanel.append(text)
    })

    // Initial status
    if (opts.executionBlocked) {
      this.statusBar.update('blocked')
    } else if (this.inputPanel && !this.inputPanel.allInputsSatisfied()) {
      const missing = this.inputPanel.missingInputs()
      this.statusBar.update('blocked', null, missing)
      this.runner.status = 'blocked'
    } else {
      this.statusBar.update('idle')
    }

    // Watch state store for input changes that may unblock this fence
    if (this.inputPanel) {
      opts.stateStore.on('change', () => {
        if (!opts.executionBlocked && this.runner.status === 'blocked') {
          if (this.inputPanel!.allInputsSatisfied()) {
            this.runner.status = 'idle'
            this.statusBar.update('idle')
            this.runner.emit('status', 'idle')
          }
        }
      })
    }
  }

  get hasOutput(): boolean {
    return this.outputPanel.hasOutput
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
      if (this.runner.status === 'running') return true

      this.outputPanel.clear()
      this.options.onExecute().catch(() => {})
      return true
    }

    if (key.name === 'escape') {
      if (this.runner.status === 'running') {
        this.runner.cancel()
      }
      return true
    }

    return false
  }

  protected override propagateFocusChange(hasFocus: boolean): void {
    super.propagateFocusChange(hasFocus)
    this.statusBar.setFocused(hasFocus)
    if (hasFocus) {
      this.borderColor = '#58a6ff'
    } else {
      this.borderColor = '#30363d'
    }
  }

  get inputRenderables(): InputRenderable[] {
    return this.inputPanel?.inputRenderables ?? []
  }

  get blockId(): string {
    return this.runner.blockId
  }

  get depends(): string[] {
    return this.options.metadata?.depends ?? []
  }

  get script(): string {
    return this.options.cleanBody
  }

  get metadata(): FenceMetadata | null {
    return this.options.metadata
  }

  get isAutoExecute(): boolean {
    return this.options.metadata?.auto === true
  }

  get isExecutionBlocked(): boolean {
    return this.options.executionBlocked
  }
}
