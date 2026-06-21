import { spawn } from 'node:child_process'
import { readFileSync, unlinkSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { EventEmitter } from 'node:events'
import type { StateStore } from './StateStore.js'
import { SET_OUTPUT_RE, scriptPreamble } from './script-utils.js'

export class LifecycleRunner extends EventEmitter {
  constructor(private readonly stateStore: StateStore) {
    super()
  }

  async runSetup(script: string): Promise<number> {
    return this.runScript('setup', script)
  }

  async runTeardown(script: string): Promise<number> {
    return this.runScript('teardown', script)
  }

  private async runScript(label: string, script: string): Promise<number> {
    const captureFile = join(tmpdir(), `mdjam_${label}_${process.pid}.env`)

    const wrappedScript = [...scriptPreamble(captureFile), script].join('\n')

    const initialEnv: Record<string, string | undefined> = { ...process.env }
    const env: Record<string, string | undefined> = {
      ...initialEnv,
      ...this.stateStore.toEnv(),
    }

    const proc = spawn('/bin/bash', ['-c', wrappedScript], {
      env: env as NodeJS.ProcessEnv,
      stdio: ['ignore', 'pipe', 'pipe'],
    })

    let buf = ''
    const processLine = (line: string): void => {
      const m = line.match(SET_OUTPUT_RE)
      if (m) {
        const [, key, value] = m
        // Setup/teardown writes with bare key only (no namespace prefix)
        this.stateStore.set(key, value, null)
        return
      }
      this.emit('output', line + '\n')
    }

    const pipeStream = (stream: NodeJS.ReadableStream): void => {
      stream.on('data', (chunk: Buffer) => {
        buf += chunk.toString()
        const lines = buf.split('\n')
        buf = lines.pop() ?? ''
        for (const line of lines) processLine(line)
      })
      stream.on('end', () => {
        if (buf.length > 0) processLine(buf)
        buf = ''
      })
    }

    if (proc.stdout) pipeStream(proc.stdout)
    if (proc.stderr) pipeStream(proc.stderr)

    return new Promise<number>((resolve) => {
      proc.on('close', (code) => {
        const exitCode = code ?? 1

        try {
          const exported = readFileSync(captureFile, 'utf8')
          this.captureExports(exported, initialEnv)
        } catch {}
        try { unlinkSync(captureFile) } catch {}

        this.emit('done', exitCode)
        resolve(exitCode)
      })
    })
  }

  private captureExports(
    exportOutput: string,
    prevEnv: Record<string, string | undefined>,
  ): void {
    for (const line of exportOutput.split('\n')) {
      const m = line.match(/^declare -x ([A-Za-z_][A-Za-z0-9_]*)(?:="((?:[^"\\]|\\.)*)")?$/)
      if (!m) continue

      const key = m[1]
      const value = m[2] ?? ''

      if (key in prevEnv) continue
      if (key.startsWith('MDJAM_') || key === '_MDJAM_CAP') continue

      // Lifecycle scripts use bare key only
      this.stateStore.set(key, value, null)
    }
  }
}
