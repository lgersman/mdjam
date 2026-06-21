import { EventEmitter } from 'node:events'

export interface StateEntry {
  value: string
  sourceBlock: string | null // null = sourced from setup script
}

export class StateStore extends EventEmitter {
  private store = new Map<string, StateEntry>()

  set(key: string, value: string, sourceBlock: string | null = null): void {
    this.store.set(key, { value, sourceBlock })
    this.emit('change', key, value, sourceBlock)
  }

  get(key: string): string | undefined {
    return this.store.get(key)?.value
  }

  getEntry(key: string): StateEntry | undefined {
    return this.store.get(key)
  }

  has(key: string): boolean {
    return this.store.has(key)
  }

  entries(): IterableIterator<[string, StateEntry]> {
    return this.store.entries()
  }

  size(): number {
    return this.store.size
  }

  clear(): void {
    this.store.clear()
    this.emit('reset')
  }

  /** Build MDJAM_<KEY>=<VALUE> environment object from store contents. */
  toEnv(): Record<string, string> {
    const env: Record<string, string> = {}
    for (const [key, entry] of this.store) {
      env[`MDJAM_${key.toUpperCase()}`] = entry.value
    }
    return env
  }
}
