import { describe, it, expect, mock } from 'bun:test'
import { StateStore } from '../../src/engine/StateStore.js'

describe('StateStore', () => {
  it('stores and retrieves values', () => {
    const store = new StateStore()
    store.set('FOO', 'bar', 'block-1')
    expect(store.get('FOO')).toBe('bar')
    expect(store.has('FOO')).toBe(true)
  })

  it('returns undefined for missing keys', () => {
    const store = new StateStore()
    expect(store.get('MISSING')).toBeUndefined()
    expect(store.has('MISSING')).toBe(false)
  })

  it('emits change event on set', () => {
    const store = new StateStore()
    const handler = mock()
    store.on('change', handler)
    store.set('KEY', 'value', 'block-1')
    expect(handler).toHaveBeenCalledWith('KEY', 'value', 'block-1')
  })

  it('emits reset event on clear', () => {
    const store = new StateStore()
    const handler = mock()
    store.on('reset', handler)
    store.set('A', '1', null)
    store.clear()
    expect(handler).toHaveBeenCalled()
    expect(store.size()).toBe(0)
  })

  it('toEnv produces MDFENCE_* prefixed entries', () => {
    const store = new StateStore()
    store.set('api_key', 'secret', null)
    store.set('HOST', 'localhost', null)
    const env = store.toEnv()
    expect(env['MDFENCE_API_KEY']).toBe('secret')
    expect(env['MDFENCE_HOST']).toBe('localhost')
  })

  it('preserves source block in entry', () => {
    const store = new StateStore()
    store.set('FOO', 'val', 'my-block')
    expect(store.getEntry('FOO')?.sourceBlock).toBe('my-block')
  })

  it('null sourceBlock for setup entries', () => {
    const store = new StateStore()
    store.set('SETUP_VAR', 'x')
    expect(store.getEntry('SETUP_VAR')?.sourceBlock).toBeNull()
  })
})
