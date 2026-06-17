import type { StateStore } from './StateStore.js'
import type { BlockRunner } from './BlockRunner.js'
import type { DependencyGraph } from '../parser/dependency.js'
import { resolveExecutionOrder } from '../parser/dependency.js'

export interface FenceBlock {
  id: string
  depends: string[]
  runner: BlockRunner
  script: string
}

export class ExecutionEngine {
  private successfulBlocks = new Set<string>()
  private failedBlocks = new Set<string>()

  constructor(
    private readonly stateStore: StateStore,
    private readonly graph: DependencyGraph,
    private readonly allBlocks: Map<string, FenceBlock>,
  ) {}

  /** Execute a block, first resolving and running any unrun dependencies. */
  async execute(target: FenceBlock): Promise<boolean> {
    if (!await this.resolveDeps(target)) return false
    return this.runBlock(target)
  }

  /** Like execute(), but runs the target block in a PTY interactive session. */
  async executeInteractive(
    target: FenceBlock,
    suspend: () => void,
    resume: () => void,
  ): Promise<boolean> {
    if (!await this.resolveDeps(target)) return false

    const exitCode = await target.runner.runInteractive(target.script, suspend, resume)
    const success = exitCode === 0
    if (success) this.successfulBlocks.add(target.id)
    else this.failedBlocks.add(target.id)
    return success
  }

  private async resolveDeps(target: FenceBlock): Promise<boolean> {
    if (this.graph.cyclesByBlock.has(target.id)) return false

    this.successfulBlocks.delete(target.id)
    this.failedBlocks.delete(target.id)

    const depsMap = new Map(
      Array.from(this.allBlocks.values()).map(b => [b.id, b.depends])
    )
    const execOrder = resolveExecutionOrder(target.id, depsMap, this.graph)

    for (const id of execOrder) {
      if (id === target.id) continue
      if (this.failedBlocks.has(id)) {
        target.runner.emit('status', 'dep-failed')
        return false
      }
      if (!this.successfulBlocks.has(id)) {
        const dep = this.allBlocks.get(id)
        if (!dep) continue
        const ok = await this.runBlock(dep)
        if (!ok) {
          target.runner.emit('status', 'dep-failed')
          return false
        }
      }
    }
    return true
  }

  private async runBlock(block: FenceBlock): Promise<boolean> {
    if (this.successfulBlocks.has(block.id)) return true

    const exitCode = await block.runner.run(block.script)
    const success = exitCode === 0

    if (success) {
      this.successfulBlocks.add(block.id)
    } else {
      this.failedBlocks.add(block.id)
    }
    return success
  }

}
