import { describe, it, expect, vi } from 'vitest'
import { BlockRunner } from '../../src/engine/BlockRunner.js'
import { StateStore } from '../../src/engine/StateStore.js'

describe('BlockRunner', () => {
  it('runs a simple script and returns exit code 0', async () => {
    const store = new StateStore()
    const runner = new BlockRunner('test-block', store)
    const code = await runner.run('echo hello')
    expect(code).toBe(0)
    expect(runner.status).toBe('success')
  })

  it('captures stdout output', async () => {
    const store = new StateStore()
    const runner = new BlockRunner('test-block', store)
    const lines: string[] = []
    runner.on('output', (text: string) => lines.push(text))
    await runner.run('echo hello world')
    expect(lines.join('').trim()).toBe('hello world')
  })

  it('intercepts ::set-output lines', async () => {
    const store = new StateStore()
    const runner = new BlockRunner('my-block', store)
    const outputs: Array<[string, string]> = []
    runner.on('setOutput', (k: string, v: string) => outputs.push([k, v]))

    await runner.run("echo '::set-output name=MY_KEY::my_value'")

    expect(outputs.length).toBeGreaterThan(0)
    const found = outputs.find(([k]) => k === 'MY_KEY')
    expect(found).toBeDefined()
    expect(found![1]).toBe('my_value')
    expect(store.get('MY_KEY')).toBe('my_value')
  })

  it('does not show ::set-output lines in output', async () => {
    const store = new StateStore()
    const runner = new BlockRunner('test', store)
    const lines: string[] = []
    runner.on('output', (text: string) => lines.push(text))
    await runner.run("echo '::set-output name=K::V'\necho visible")
    expect(lines.join('')).not.toContain('::set-output')
    expect(lines.join('').trim()).toBe('visible')
  })

  it('returns non-zero exit code on failure', async () => {
    const store = new StateStore()
    const runner = new BlockRunner('fail-block', store)
    const code = await runner.run('exit 42')
    expect(code).toBe(42)
    expect(runner.status).toBe('failed')
    expect(runner.exitCode).toBe(42)
  })

  it('captures plain exports from script', async () => {
    const store = new StateStore()
    const runner = new BlockRunner('export-block', store)
    await runner.run('export NEW_VAR=exported_value')
    expect(store.get('NEW_VAR')).toBe('exported_value')
  })

  it('injects MDFENCE_* env vars from state store', async () => {
    const store = new StateStore()
    store.set('MY_TOKEN', 'abc123', null)
    const runner = new BlockRunner('test', store)
    const lines: string[] = []
    runner.on('output', (t: string) => lines.push(t))
    await runner.run('echo "$MDFENCE_MY_TOKEN"')
    expect(lines.join('').trim()).toBe('abc123')
  })
})
