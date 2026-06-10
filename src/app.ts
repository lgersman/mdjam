import {
  createCliRenderer,
  MarkdownRenderable,
  BoxRenderable,
  ScrollBoxRenderable,
  TextRenderable,
  createMarkdownCodeBlockRenderer,
  type RenderContext,
} from '@opentui/core'
import type { Tokens } from 'marked'
import { readFileSync, watch } from 'node:fs'
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

export interface AppOptions {
  filePath: string
  theme: ThemeName
  noAuto: boolean
  noWatch: boolean
}

export async function runApp(options: AppOptions): Promise<void> {
  const renderer = await createCliRenderer({
    exitOnCtrlC: false,
    exitSignals: [],
    autoFocus: true,
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
  rootBox.add(scrollBox)

  // State side panel (overlay)
  const statePanel = new StateSidePanel(renderer, new StateStore())
  renderer.root.add(statePanel)

  // Teardown panel (shown on exit)
  const teardownPanel = new TeardownPanel(renderer)
  rootBox.add(teardownPanel)

  // Mutable session state, recreated on reload
  let fenceRenderables: CodeFenceRenderable[] = []
  let teardownScript: string | undefined
  let currentMarkdown: MarkdownRenderable | null = null
  let currentStateStore = new StateStore()
  let executionEngine: ExecutionEngine | null = null
  let allBlocks = new Map<string, FenceBlock>()

  async function loadDocument(): Promise<void> {
    // Cleanup previous session
    fenceRenderables.forEach(r => {
      try { r.destroyRecursively() } catch {}
    })
    fenceRenderables = []
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

    currentMarkdown = new MarkdownRenderable(renderer, {
      content: body,
      syntaxStyle,
      renderNode: codeBlockRenderer,
      conceal: true,
      flexShrink: 0,
      width: '100%',
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

  // Focus management: cycle through focusable code fences
  let focusIndex = -1

  function focusNext(delta: 1 | -1): void {
    const focusable = fenceRenderables.filter(f => !f.isExecutionBlocked)
    if (focusable.length === 0) return

    focusIndex = (focusIndex + delta + focusable.length) % focusable.length
    renderer.focusRenderable(focusable[focusIndex])
  }

  // Global keyboard handler
  renderer.keyInput.on('keypress', async (key) => {
    // Skip if an input field has focus
    const focused = renderer.currentFocusedRenderable
    if (focused && !(focused instanceof CodeFenceRenderable)) {
      // Let the focused element handle it
      return
    }

    switch (key.name) {
      case 'q':
        await quit()
        break

      case 'r':
        focusIndex = -1
        await loadDocument()
        break

      case 's':
        statePanel.toggle()
        break

      case 'j':
      case 'down':
        scrollBox.scrollBy(3)
        break

      case 'k':
      case 'up':
        scrollBox.scrollBy(-3)
        break

      case 'space':
      case 'pagedown':
        scrollBox.scrollBy(renderer.height - 2)
        break

      case 'b':
      case 'pageup':
        scrollBox.scrollBy(-(renderer.height - 2))
        break

      case 'g':
        if (!key.shift) {
          scrollBox.scrollTo(0)
        }
        break

      case 'G':
        scrollBox.scrollTo({ x: 0, y: scrollBox.scrollHeight })
        break

      case 'tab':
        key.preventDefault()
        if (key.shift) {
          focusNext(-1)
        } else {
          focusNext(1)
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
          focusIndex = -1
          await loadDocument()
          reloadTimer = null
        }, 200)
      })
    } catch {
      // Watch not available on all platforms
    }
  }
}
