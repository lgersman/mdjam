import {
  createCliRenderer,
  MarkdownRenderable,
  BoxRenderable,
  CodeRenderable,
  ScrollBoxRenderable,
  TextRenderable,
  InputRenderable,
  createMarkdownCodeBlockRenderer,
  createTextAttributes,
  type RenderContext,
  type RenderNodeContext,
} from '@opentui/core'
import type { PasteEvent } from '@opentui/core/lib/KeyHandler.js'
import type { Token, Tokens } from 'marked'
import { readFileSync, watch } from 'node:fs'
import yaml from 'js-yaml'
import { parseFrontmatter } from './parser/frontmatter.js'
import { parseFenceMetadata, extractFenceNodes } from './parser/metadata.js'
import { buildDependencyGraph } from './parser/dependency.js'
import { StateStore } from './engine/StateStore.js'
import { BlockRunner } from './engine/BlockRunner.js'
import { LifecycleRunner } from './engine/LifecycleRunner.js'
import { ExecutionEngine, type FenceBlock } from './engine/ExecutionEngine.js'
import { checkPrerequisites } from './engine/Prerequisites.js'
import { createSyntaxStyle, type ThemeName } from './theme/themes.js'
import { CodeFenceRenderable } from './components/CodeFenceRenderable.js'
import { PrerequisitePanel } from './components/PrerequisitePanel.js'
import { SetupErrorPanel } from './components/SetupErrorPanel.js'
import { StateSidePanel } from './components/StateSidePanel.js'
import { TeardownPanel } from './components/TeardownPanel.js'
import { HelpPanel } from './components/HelpPanel.js'
import { FrontmatterPanel } from './components/FrontmatterPanel.js'
import { BottomStatusBar } from './components/BottomStatusBar.js'
import type { BlockStatus } from './engine/BlockRunner.js'

export interface AppOptions {
  filePath: string
  theme: ThemeName
  noAuto: boolean
  noWatch: boolean
  verbose: boolean
}

export async function runApp(options: AppOptions): Promise<void> {
  const renderer = await createCliRenderer({
    exitOnCtrlC: false,
    exitSignals: [],
    autoFocus: true,
    useMouse: true,
    useKittyKeyboard: {},
  })

  const syntaxStyle = createSyntaxStyle(options.theme)

  // Top-level layout: full-screen flex column
  const rootBox = new BoxRenderable(renderer, {
    flexDirection: 'column',
    width: '100%',
    height: '100%',
  })
  renderer.root.add(rootBox)

  // Scrollable document area
  const scrollBox = new ScrollBoxRenderable(renderer, {
    flexGrow: 1,
    width: '100%',
    scrollY: true,
    scrollX: false,
  })
  scrollBox.verticalScrollBar.visible = false
  scrollBox.selectable = true
  rootBox.add(scrollBox)

  // State side panel (overlay)
  const statePanel = new StateSidePanel(renderer, new StateStore())
  renderer.root.add(statePanel)

  // Help panel (overlay)
  const helpPanel = new HelpPanel(renderer)
  renderer.root.add(helpPanel)

  // Static status bar at bottom
  const bottomStatusBar = new BottomStatusBar(renderer)
  rootBox.add(bottomStatusBar)

  // Teardown panel (shown on exit)
  const teardownPanel = new TeardownPanel(renderer)
  rootBox.add(teardownPanel)

  // Mutable session state, recreated on reload
  let fenceRenderables: CodeFenceRenderable[] = []
  let frontmatterPanel: FrontmatterPanel | null = null
  let teardownScript: string | undefined
  let currentMarkdown: MarkdownRenderable | null = null
  let currentStateStore = new StateStore()
  let executionEngine: ExecutionEngine | null = null
  let allBlocks = new Map<string, FenceBlock>()

  // Focus tracking for bottom status bar
  let trackedFence: CodeFenceRenderable | null = null
  let trackedStatusListener: ((status: BlockStatus, exitCode?: number) => void) | null = null

  function attachFenceStatusListener(fence: CodeFenceRenderable | null): void {
    if (trackedFence && trackedStatusListener) {
      trackedFence.runner.off('status', trackedStatusListener)
    }
    trackedFence = fence
    trackedStatusListener = null
    if (fence) {
      trackedStatusListener = (status: BlockStatus, exitCode?: number) => {
        bottomStatusBar.updateBlockStatus(status, exitCode, fence.missingInputs)
      }
      fence.runner.on('status', trackedStatusListener)
      bottomStatusBar.updateBlockStatus(fence.runner.status, fence.runner.exitCode ?? undefined, fence.missingInputs)
    }
  }

  async function loadDocument(): Promise<void> {
    // Detach status bar listener before destroying fences
    attachFenceStatusListener(null)
    bottomStatusBar.setContext('markdown')

    // Cleanup previous session
    fenceRenderables.forEach(r => {
      try { r.destroyRecursively() } catch {}
    })
    fenceRenderables = []
    if (frontmatterPanel) {
      try { frontmatterPanel.destroyRecursively() } catch {}
      frontmatterPanel = null
    }
    allBlocks = new Map()
    currentStateStore.clear()

    if (currentMarkdown) {
      try { currentMarkdown.destroyRecursively() } catch {}
      currentMarkdown = null
    }
    // Remove all children from scrollBox.content
    for (const child of scrollBox.content.getChildren()) {
      scrollBox.content.remove(child.id)
    }

    // Read the file
    let content: string
    try {
      content = readFileSync(options.filePath, 'utf8')
    } catch (err) {
      const errBox = new BoxRenderable(renderer, { flexDirection: 'column', padding: 1 })
      errBox.add(new TextRenderable(renderer, {
        content: `Error reading file: ${err instanceof Error ? err.message : String(err)}`,
        fg: '#f85149',
      }))
      scrollBox.content.add(errBox)
      return
    }

    const { frontmatter, body } = parseFrontmatter(content)
    teardownScript = frontmatter.teardown

    // Apply document defaults to store
    currentStateStore = new StateStore()
    statePanel.setStore(currentStateStore)

    for (const [key, value] of Object.entries(frontmatter.defaults ?? {})) {
      currentStateStore.set(key, value, null)
    }

    // Interactive defaults panel — always shown when defaults exist
    const defaults = frontmatter.defaults ?? {}
    if (Object.keys(defaults).length > 0) {
      frontmatterPanel = new FrontmatterPanel(renderer, defaults, currentStateStore)
      scrollBox.content.add(frontmatterPanel)
    }

    // Verbose: render non-defaults frontmatter fields as YAML
    if (options.verbose) {
      const { defaults: _defaults, ...rest } = frontmatter
      const fields = Object.fromEntries(
        Object.entries(rest).filter(([, v]) => v !== undefined)
      )
      if (Object.keys(fields).length > 0) {
        const headerBox = new BoxRenderable(renderer, {
          flexDirection: 'column',
          flexShrink: 0,
          marginBottom: 1,
          border: true,
          borderColor: '#30363d',
        })
        headerBox.add(new TextRenderable(renderer, {
          content: '  Frontmatter',
          fg: '#8b949e',
          italic: true,
          flexShrink: 0,
        } as any))
        headerBox.add(new CodeRenderable(renderer, {
          content: yaml.dump(fields, { indent: 2, lineWidth: -1 }).trimEnd(),
          filetype: 'yaml',
          syntaxStyle,
          conceal: false,
          flexShrink: 0,
          paddingLeft: 2,
          paddingBottom: 1,
        }))
        scrollBox.content.add(headerBox)
      }
    }

    // Check prerequisites
    const prereqResult = checkPrerequisites(frontmatter.prerequisites ?? {})
    let executionBlocked = prereqResult.failed.length > 0

    if (executionBlocked) {
      const panel = new PrerequisitePanel(renderer, prereqResult)
      scrollBox.content.add(panel)
    }

    // Run setup if prereqs pass
    if (!executionBlocked && frontmatter.setup) {
      const lifecycleRunner = new LifecycleRunner(currentStateStore)
      const setupPanel = new SetupErrorPanel(renderer, 0)
      lifecycleRunner.on('output', (text: string) => {
        setupPanel.appendOutput(text)
      })

      const exitCode = await lifecycleRunner.runSetup(frontmatter.setup)
      if (exitCode !== 0) {
        // Rebuild panel with actual exit code
        const errPanel = new SetupErrorPanel(renderer, exitCode)
        lifecycleRunner.removeAllListeners('output')
        scrollBox.content.add(errPanel)
        executionBlocked = true
      }
    }

    // Build dependency graph by pre-scanning the body
    const fenceNodes = extractFenceNodes(body)
    const graph = buildDependencyGraph(fenceNodes)
    allBlocks = new Map()
    executionEngine = new ExecutionEngine(currentStateStore, graph, allBlocks)

    let fenceIndex = 0

    // Create code fence renderer for bash/sh
    const bashRenderer = (token: Tokens.Code) => {
      const { metadata, cleanBody, parseError } = parseFenceMetadata(token.text)
      const blockId = metadata?.id ?? `__fence_${fenceIndex++}`
      const runner = new BlockRunner(blockId, currentStateStore)

      const fence = new CodeFenceRenderable(renderer, {
        token,
        cleanBody,
        metadata,
        parseError,
        runner,
        stateStore: currentStateStore,
        syntaxStyle,
        executionBlocked,
        onExecute: async () => {
          const block: FenceBlock = {
            id: blockId,
            depends: metadata?.depends ?? [],
            runner,
            script: cleanBody,
          }
          allBlocks.set(blockId, block)
          if (executionEngine) {
            await executionEngine.execute(block)
          }
        },
      })

      fenceRenderables.push(fence)

      // Register block for dependency resolution
      const block: FenceBlock = {
        id: blockId,
        depends: metadata?.depends ?? [],
        runner,
        script: cleanBody,
      }
      allBlocks.set(blockId, block)

      return fence
    }

    const codeBlockRenderer = createMarkdownCodeBlockRenderer({
      bash: bashRenderer,
      sh: bashRenderer,
    })

    const patchListBullets = (box: BoxRenderable): void => {
      for (const child of box.getChildren()) {
        if (!(child instanceof BoxRenderable)) continue
        const rowChildren = child.getChildren()
        const marker = rowChildren[0]
        if (marker instanceof TextRenderable && marker.chunks[0]?.text === '- ') {
          marker.content = '• '
        }
        patchListBullets(child)
      }
    }

    const renderNode = (token: Token, context: RenderNodeContext) => {
      if (token.type === 'heading') {
        const h = token as Tokens.Heading
        const style = context.syntaxStyle.getStyle('markup.heading')
        return new TextRenderable(renderer, {
          content: `${'#'.repeat(h.depth)} ${h.text}`,
          fg: style?.fg,
          attributes: createTextAttributes({ bold: true }),
          flexShrink: 0,
          width: '100%',
        } as any)
      }
      if (token.type === 'list' && !(token as Tokens.List).ordered) {
        const defaultRenderable = context.defaultRender()
        if (defaultRenderable instanceof BoxRenderable) {
          patchListBullets(defaultRenderable)
        }
        return defaultRenderable
      }
      return codeBlockRenderer(token, context)
    }

    currentMarkdown = new MarkdownRenderable(renderer, {
      content: body,
      syntaxStyle,
      renderNode,
      conceal: true,
      flexShrink: 0,
      width: '100%',
      tableOptions: {
        style: 'grid',
        borderStyle: 'rounded',
        cellPaddingX: 1,
      },
    })

    scrollBox.content.add(currentMarkdown)

    // Auto-execute blocks with auto: true
    if (!options.noAuto && !executionBlocked) {
      for (const fence of fenceRenderables) {
        if (fence.isAutoExecute) {
          const block = allBlocks.get(fence.blockId)
          if (block && executionEngine) {
            executionEngine.execute(block).catch(() => {})
          }
        }
      }
    }
  }

  // Initial load
  await loadDocument()

  // Focus management: flat list of fences (no inputs) and variable editors (fences with inputs)
  type FocusItem =
    | { kind: 'fence'; fence: CodeFenceRenderable }
    | { kind: 'input'; input: InputRenderable; fence: CodeFenceRenderable }
    | { kind: 'fm-input'; input: InputRenderable; panel: FrontmatterPanel }

  function buildFocusList(): FocusItem[] {
    const items: FocusItem[] = []

    if (frontmatterPanel) {
      for (const input of frontmatterPanel.inputRenderables) {
        items.push({ kind: 'fm-input', input, panel: frontmatterPanel })
      }
    }

    for (const fence of fenceRenderables) {
      if (fence.isExecutionBlocked) continue
      const inputs = fence.inputRenderables
      if (inputs.length > 0) {
        for (const input of inputs) {
          items.push({ kind: 'input', input, fence })
        }
      } else {
        items.push({ kind: 'fence', fence })
      }
    }
    return items
  }

  function updateStatusBar(): void {
    const focused = renderer.currentFocusedRenderable

    if (focused instanceof CodeFenceRenderable) {
      bottomStatusBar.setContext('codeblock')
      attachFenceStatusListener(focused)
    } else if (focused instanceof InputRenderable) {
      const items = buildFocusList()
      const item = items.find(i =>
        (i.kind === 'input' && i.input === focused) ||
        (i.kind === 'fm-input' && i.input === focused)
      )
      if (item?.kind === 'input') {
        bottomStatusBar.setContext('block-input')
        attachFenceStatusListener(item.fence)
      } else {
        bottomStatusBar.setContext('fm-input')
        attachFenceStatusListener(null)
      }
    } else {
      attachFenceStatusListener(null)
      bottomStatusBar.setContext('markdown')
    }
  }

  function focusNext(delta: 1 | -1): void {
    const items = buildFocusList()
    if (items.length === 0) return

    const focused = renderer.currentFocusedRenderable
    let currentIndex = -1
    if (focused instanceof CodeFenceRenderable) {
      currentIndex = items.findIndex(i => i.kind === 'fence' && i.fence === focused)
    } else if (focused instanceof InputRenderable) {
      currentIndex = items.findIndex(i =>
        (i.kind === 'input' && i.input === focused) ||
        (i.kind === 'fm-input' && i.input === focused)
      )
    }

    // When nothing is focused, enter the list from the appropriate end
    const nextIndex = currentIndex === -1
      ? (delta === 1 ? 0 : items.length - 1)
      : currentIndex + delta

    if (nextIndex < 0 || nextIndex >= items.length) return

    const item = items[nextIndex]
    if (item.kind === 'fence') {
      item.fence.focus()
      scrollBox.scrollChildIntoView(item.fence.id)
    } else if (item.kind === 'input') {
      item.input.focus()
      scrollBox.scrollChildIntoView(item.fence.id)
    } else {
      item.input.focus()
      scrollBox.scrollChildIntoView(item.panel.id)
    }
    updateStatusBar()
  }

  // Global keyboard handler
  renderer.keyInput.on('paste', (event: PasteEvent) => {
    const focused = renderer.currentFocusedRenderable
    if (!(focused instanceof InputRenderable)) {
      const text = new TextDecoder().decode(event.bytes)
      if (text.trim()) {
        bottomStatusBar.flash('Focus an input to paste  [Tab] to navigate')
      }
    }
  })

  renderer.keyInput.on('keypress', async (key) => {
    if (key.name === 'c' && key.ctrl && key.shift) {
      key.stopPropagation()
      if (renderer.hasSelection) {
        const text = renderer.getSelection()!.getSelectedText()
        if (text.trim()) {
          renderer.copyToClipboardOSC52(text)
          bottomStatusBar.flash('Copied to clipboard')
        }
      }
      return
    }

    if (key.name === 'c' && key.ctrl && !key.shift) {
      await quit()
      return
    }

    // Tab navigation is global — must be handled before the InputRenderable guard
    if (key.name === 'tab') {
      key.preventDefault()
      focusNext(key.shift ? -1 : 1)
      return
    }

    // Skip global navigation when a text input has focus
    const focused = renderer.currentFocusedRenderable
    if (focused instanceof InputRenderable) {
      if (key.name === 'escape') {
        focused.blur()
        updateStatusBar()
      }
      return
    }

    const focusedFence = focused instanceof CodeFenceRenderable && focused.hasOutput ? focused : null

    switch (key.name) {
      case 'h':
        helpPanel.toggle()
        break

      case 'escape':
        if (helpPanel.visible) {
          helpPanel.toggle()
          break
        }
        focused?.blur()
        updateStatusBar()
        break

      case 'r':
        await loadDocument()
        updateStatusBar()
        break

      case 's':
        statePanel.toggle()
        break

      case 'j':
      case 'down':
        if (focusedFence) {
          focusedFence.scrollOutputBy(3)
        } else {
          scrollBox.scrollBy(3)
        }
        break

      case 'k':
      case 'up':
        if (focusedFence) {
          focusedFence.scrollOutputBy(-3)
        } else {
          scrollBox.scrollBy(-3)
        }
        break

      case 'space':
      case 'pagedown':
        if (focusedFence) {
          focusedFence.scrollOutputBy(10)
        } else {
          scrollBox.scrollBy(renderer.height - 2)
        }
        break

      case 'b':
      case 'pageup':
        if (focusedFence) {
          focusedFence.scrollOutputBy(-10)
        } else {
          scrollBox.scrollBy(-(renderer.height - 2))
        }
        break

      case 'g':
        if (!key.shift) {
          if (focusedFence) {
            focusedFence.scrollOutputTo(0)
          } else {
            scrollBox.scrollTo(0)
          }
        }
        break

      case 'G':
        if (focusedFence) {
          focusedFence.scrollOutputTo({ x: 0, y: focusedFence.outputScrollHeight })
        } else {
          scrollBox.scrollTo({ x: 0, y: scrollBox.scrollHeight })
        }
        break

    }
  })

  async function quit(): Promise<void> {
    if (teardownScript) {
      const lifecycleRunner = new LifecycleRunner(currentStateStore)
      lifecycleRunner.on('output', (text: string) => {
        teardownPanel.appendOutput(text)
        teardownPanel.visible = true
      })
      await lifecycleRunner.runTeardown(teardownScript)
    }
    renderer.destroy()
    process.exit(0)
  }

  // Handle Ctrl+C manually for teardown
  process.on('SIGINT', async () => {
    await quit()
  })

  process.on('SIGTERM', async () => {
    await quit()
  })

  // Watch mode
  if (!options.noWatch) {
    let reloadTimer: ReturnType<typeof setTimeout> | null = null
    try {
      watch(options.filePath, () => {
        if (reloadTimer) clearTimeout(reloadTimer)
        reloadTimer = setTimeout(async () => {
          await loadDocument()
          reloadTimer = null
        }, 200)
      })
    } catch {
      // Watch not available on all platforms
    }
  }
}
