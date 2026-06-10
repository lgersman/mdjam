import { spawn } from 'node:child_process'
import { readFileSync, unlinkSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { EventEmitter } from 'node:events'
import type { StateStore } from './StateStore.js'

export type BlockStatus =
  | 'idle'
  | 'running'
  | 'success'
  | 'failed'
  | 'cancelled'
  | 'blocked'
  | 'dep-failed'

const SET_OUTPUT_RE = /^::set-output name=([^:]+)::(.*)$/

export class BlockRunner extends EventEmitter {
  readonly blockId: string
  status: BlockStatus = 'idle'
  exitCode: number | null = null
  private proc: ReturnType<typeof spawn> | null = null
  private readonly stateStore: StateStore

  constructor(blockId: string, stateStore: StateStore) {
    super()
    this.blockId = blockId
    this.stateStore = stateStore
  }

  async run(script: string): Promise<number> {
    // Kill any running process first
    this.cancelInternal()

    this.setStatus('running')

    const captureFile = join(tmpdir(), `mdrun_${this.blockId.replace(/[^a-z0-9]/gi, '_')}_${process.pid}.env`)

    // Wrap script: always capture exports on exit via trap
    const wrappedScript = [
      `_MDRUN_CAP="${captureFile}"`,
      `trap 'export -p > "$_MDRUN_CAP" 2>/dev/null || true' EXIT`,
      script,
    ].join('\n')

    const initialEnv: Record<string, string | undefined> = { ...process.env }
    const env: Record<string, string | undefined> = {
      ...initialEnv,
      ...this.stateStore.toEnv(),
    }

    this.proc = spawn('/bin/bash', ['-c', wrappedScript], {
      env: env as NodeJS.ProcessEnv,
      stdio: ['ignore', 'pipe', 'pipe'],
    })

    const processOutputLine = (line: string, isStderr: boolean): void => {
      if (!isStderr) {
        const m = line.match(SET_OUTPUT_RE)
        if (m) {
          const [, key, value] = m
          // Write bare key + namespaced key to state store
          this.stateStore.set(key, value, this.blockId)
          this.stateStore.set(`${this.blockId}.${key}`, value, this.blockId)
          this.emit('setOutput', key, value)
          return
        }
      }
      this.emit('output', line + '\n')
    }

    const pipeStream = (stream: NodeJS.ReadableStream, isStderr: boolean): void => {
      let buf = ''
      stream.on('data', (chunk: Buffer) => {
        buf += chunk.toString()
        const lines = buf.split('\n')
        buf = lines.pop() ?? ''
        for (const line of lines) processOutputLine(line, isStderr)
      })
      stream.on('end', () => {
        if (buf.length > 0) processOutputLine(buf, isStderr)
      })
    }

    if (this.proc.stdout) pipeStream(this.proc.stdout, false)
    if (this.proc.stderr) pipeStream(this.proc.stderr, true)

    return new Promise<number>((resolve) => {
      this.proc!.on('close', (code, signal) => {
        const exitCode = code ?? (signal ? 1 : 0)

        try {
          const capturedEnv = readFileSync(captureFile, 'utf8')
          this.captureExports(capturedEnv, initialEnv)
        } catch {
          // File may not exist if trap didn't fire (e.g. SIGKILL)
        }
        try { unlinkSync(captureFile) } catch {}

        if (this.status !== 'cancelled') {
          this.exitCode = exitCode
          this.setStatus(exitCode === 0 ? 'success' : 'failed', exitCode)
        }

        this.proc = null
        this.emit('done', exitCode)
        resolve(exitCode)
      })
    })
  }

  cancel(): void {
    this.cancelInternal()
  }

  private cancelInternal(): void {
    if (!this.proc) return
    this.setStatus('cancelled')
    const proc = this.proc
    this.proc = null
    proc.kill('SIGTERM')
    setTimeout(() => {
      try { proc.kill('SIGKILL') } catch {}
    }, 3000)
  }

  private captureExports(
    exportOutput: string,
    prevEnv: Record<string, string | undefined>,
  ): void {
    for (const line of exportOutput.split('\n')) {
      // bash "export -p" format: declare -x KEY="VALUE" or declare -x KEY
      const m = line.match(/^declare -x ([A-Za-z_][A-Za-z0-9_]*)(?:="((?:[^"\\]|\\.)*)")?$/)
      if (!m) continue

      const key = m[1]
      const value = m[2] ?? ''

      // Skip vars that existed before the block ran
      if (key in prevEnv) continue
      // Skip injected and internal vars
      if (key.startsWith('MDFENCE_') || key === '_MDRUN_CAP') continue

      this.stateStore.set(key, value, this.blockId)
      this.stateStore.set(`${this.blockId}.${key}`, value, this.blockId)
    }
  }

  private setStatus(status: BlockStatus, code?: number): void {
    this.status = status
    if (code !== undefined) this.exitCode = code
    this.emit('status', status, code)
  }
}
