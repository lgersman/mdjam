export interface FenceNode {
  id: string
  depends: string[]
}

export interface DependencyGraph {
  executionOrder: string[]
  cyclesByBlock: Map<string, string[]>
}

export function buildDependencyGraph(nodes: FenceNode[]): DependencyGraph {
  const nodeMap = new Map(nodes.map(n => [n.id, n]))
  const visited = new Set<string>()
  const visiting = new Set<string>()
  const executionOrder: string[] = []
  const cyclesByBlock = new Map<string, string[]>()

  function visit(id: string, path: string[]): void {
    if (visiting.has(id)) {
      const cycleStart = path.indexOf(id)
      const cycle = path.slice(cycleStart)
      for (const cycleId of cycle) {
        if (!cyclesByBlock.has(cycleId)) {
          cyclesByBlock.set(cycleId, cycle)
        }
      }
      return
    }
    if (visited.has(id)) return

    visiting.add(id)
    const node = nodeMap.get(id)
    if (node) {
      for (const dep of node.depends) {
        visit(dep, [...path, id])
      }
    }
    visiting.delete(id)
    visited.add(id)
    executionOrder.push(id)
  }

  for (const node of nodes) {
    if (!visited.has(node.id)) {
      visit(node.id, [])
    }
  }

  return { executionOrder, cyclesByBlock }
}

/** Return IDs in topological execution order needed to run the given target. */
export function resolveExecutionOrder(
  targetId: string,
  depsMap: Map<string, string[]>,
  graph: DependencyGraph,
): string[] {
  const needed = new Set<string>()

  function collect(id: string): void {
    if (needed.has(id)) return
    needed.add(id)
    for (const dep of depsMap.get(id) ?? []) {
      collect(dep)
    }
  }

  collect(targetId)
  return graph.executionOrder.filter(id => needed.has(id))
}
