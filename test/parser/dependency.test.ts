import { describe, it, expect } from 'vite-plus/test'
import { buildDependencyGraph, resolveExecutionOrder } from '../../src/parser/dependency.js'

describe('buildDependencyGraph', () => {
  it('returns empty order for empty input', () => {
    const graph = buildDependencyGraph([])
    expect(graph.executionOrder).toEqual([])
    expect(graph.cyclesByBlock.size).toBe(0)
  })

  it('produces topological order for a linear chain', () => {
    const nodes = [
      { id: 'a', depends: [] },
      { id: 'b', depends: ['a'] },
      { id: 'c', depends: ['b'] },
    ]
    const graph = buildDependencyGraph(nodes)
    expect(graph.cyclesByBlock.size).toBe(0)

    const aIdx = graph.executionOrder.indexOf('a')
    const bIdx = graph.executionOrder.indexOf('b')
    const cIdx = graph.executionOrder.indexOf('c')
    expect(aIdx).toBeLessThan(bIdx)
    expect(bIdx).toBeLessThan(cIdx)
  })

  it('detects a simple cycle', () => {
    const nodes = [
      { id: 'a', depends: ['b'] },
      { id: 'b', depends: ['a'] },
    ]
    const graph = buildDependencyGraph(nodes)
    expect(graph.cyclesByBlock.size).toBeGreaterThan(0)
  })

  it('handles diamond dependency', () => {
    // a → b, a → c, b → d, c → d
    const nodes = [
      { id: 'a', depends: ['b', 'c'] },
      { id: 'b', depends: ['d'] },
      { id: 'c', depends: ['d'] },
      { id: 'd', depends: [] },
    ]
    const graph = buildDependencyGraph(nodes)
    expect(graph.cyclesByBlock.size).toBe(0)
    const dIdx = graph.executionOrder.indexOf('d')
    const bIdx = graph.executionOrder.indexOf('b')
    const cIdx = graph.executionOrder.indexOf('c')
    const aIdx = graph.executionOrder.indexOf('a')
    expect(dIdx).toBeLessThan(bIdx)
    expect(dIdx).toBeLessThan(cIdx)
    expect(bIdx).toBeLessThan(aIdx)
    expect(cIdx).toBeLessThan(aIdx)
  })
})

describe('resolveExecutionOrder', () => {
  it('returns only needed nodes in order', () => {
    const nodes = [
      { id: 'a', depends: [] },
      { id: 'b', depends: ['a'] },
      { id: 'c', depends: [] },
    ]
    const graph = buildDependencyGraph(nodes)
    const depsMap = new Map([
      ['a', []],
      ['b', ['a']],
      ['c', []],
    ])
    const order = resolveExecutionOrder('b', depsMap, graph)
    expect(order).toContain('a')
    expect(order).toContain('b')
    expect(order).not.toContain('c')

    const aIdx = order.indexOf('a')
    const bIdx = order.indexOf('b')
    expect(aIdx).toBeLessThan(bIdx)
  })
})
