import { spawn } from 'node:child_process'
import { readFileSync, writeFileSync, unlinkSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { EventEmitter } from 'node:events'
import type { StateStore } from './StateStore.js'
import { SET_OUTPUT_RE, scriptPreamble } from './script-utils.js'

// Strip ANSI then resolve \r overwrite semantics to get visible lines.
// A bare \r in a PTY record means "cursor to col 0" (overwrites previous text).
// Splitting by \r and taking the last segment gives what the terminal would show.
function terminalLines(raw: string): string[] {
  const stripped = raw
    .replace(/\x1b\[[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]/g, '') // CSI sequences
    .replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, '')          // OSC sequences
    .replace(/\x1b[\x20-\x2f]?[\x30-\x7e]/g, '')                // 2-char escapes
    .replace(/\x1b/g, '')                                        // stray ESC
  // Split on \n, then within each visual line take only the text after the last \r.
  // PTY lines end with \r\n; after splitting on \n the trailing \r is a line-ending
  // artifact, not an overwrite — strip it before handling mid-line \r overwrites.
  return stripped.split('\n').map(line => {
    const trimmed = line.endsWith('\r') ? line.slice(0, -1) : line
    const parts = trimmed.split('\r')
    return parts[parts.length - 1] ?? ''
  })
}

export type BlockStatus =
  | 'idle'
  | 'running'
  | 'success'
  | 'failed'
  | 'cancelled'
  | 'blocked'
  | 'dep-failed'

export class BlockRunner extends EventEmitter {
  readonly blockId: string
  status: BlockStatus = 'idle'
  exitCode: number | null = null
  readonly stdoutLines: string[] = []
  readonly stderrLines: string[] = []
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

    this.stdoutLines.length = 0
    this.stderrLines.length = 0
    this.setStatus('running')

    const captureFile = join(tmpdir(), `mdjam_${this.blockId.replace(/[^a-z0-9]/gi, '_')}_${process.pid}.env`)

    // Wrap script: capture exports on exit + intercept ::set-output so the value
    // is also available to subsequent lines in the same block via MDJAM_*.
    const wrappedScript = [
      ...scriptPreamble(captureFile),
      `function echo() {`,
      `  command echo "$@"`,
      `  if [[ "$*" =~ ^'::set-output name='([^:]+)'::'(.*) ]]; then`,
      `    export "MDJAM_\${BASH_REMATCH[1]^^}=\${BASH_REMATCH[2]}"`,
      `  fi`,
      `}`,
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

    const pipeStream = (stream: NodeJS.ReadableStream, isStderr: boolean): void => {
      let buf = ''
      stream.on('data', (chunk: Buffer) => {
        buf += chunk.toString()
        const lines = buf.split('\n')
        buf = lines.pop() ?? ''
        for (const line of lines) this.processOutputLine(line, isStderr)
      })
      stream.on('end', () => {
        if (buf.length > 0) this.processOutputLine(buf, isStderr)
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

  async runInteractive(
    script: string,
    suspend: () => void,
    resume: () => void,
  ): Promise<number> {
    this.cancelInternal()

    this.stdoutLines.length = 0
    this.stderrLines.length = 0
    this.setStatus('running')

    const prefix = `mdjam_${this.blockId.replace(/[^a-z0-9]/gi, '_')}_${process.pid}`
    const captureFile = join(tmpdir(), `${prefix}.env`)
    const scriptFile  = join(tmpdir(), `${prefix}.sh`)
    const recordFile  = join(tmpdir(), `${prefix}.rec`)

    const wrappedScript = [
      ...scriptPreamble(captureFile),
      `function echo() {`,
      `  command echo "$@"`,
      `  if [[ "$*" =~ ^'::set-output name='([^:]+)'::'(.*) ]]; then`,
      `    export "MDJAM_\${BASH_REMATCH[1]^^}=\${BASH_REMATCH[2]}"`,
      `  fi`,
      `}`,
      script,
    ].join('\n')

    writeFileSync(scriptFile, wrappedScript, { mode: 0o700 })

    const initialEnv: Record<string, string | undefined> = { ...process.env }
    const env: Record<string, string | undefined> = {
      ...initialEnv,
      ...this.stateStore.toEnv(),
    }

    suspend()

    // `script -q -e` creates a PTY for the child, records its output,
    // and exits with the child's exit code (-e / --return, util-linux ≥2.26).
    // stdio: 'inherit' hands the real TTY fds to `script` so the user can interact.
    this.proc = spawn('script', ['-q', '-e', '-c', `bash "${scriptFile}"`, recordFile], {
      env: env as NodeJS.ProcessEnv,
      stdio: 'inherit',
    })

    return new Promise<number>((resolve) => {
      this.proc!.on('close', (code, signal) => {
        this.proc = null
        resume()

        let rawOutput = ''
        try { rawOutput = readFileSync(recordFile, 'utf8') } catch {}

        for (const line of terminalLines(rawOutput)) {
          // Filter `script` header/footer lines that appear in the record file
          if (!line.length || line.startsWith('Script started') || line.startsWith('Script done')) continue
          this.processOutputLine(line, false)
        }

        try {
          const capturedEnv = readFileSync(captureFile, 'utf8')
          this.captureExports(capturedEnv, initialEnv)
        } catch {}

        for (const f of [scriptFile, recordFile, captureFile]) {
          try { unlinkSync(f) } catch {}
        }

        const exitCode = code ?? (signal ? 1 : 0)
        if (this.status !== 'cancelled') {
          this.exitCode = exitCode
          this.setStatus(exitCode === 0 ? 'success' : 'failed', exitCode)
        }
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

  private processOutputLine(line: string, isStderr: boolean): void {
    if (!isStderr) {
      const m = line.match(SET_OUTPUT_RE)
      if (m) {
        const [, key, value] = m
        this.stateStore.set(key, value, this.blockId)
        this.stateStore.set(`${this.blockId}.${key}`, value, this.blockId)
        this.emit('setOutput', key, value)
        return
      }
      this.stdoutLines.push(line + '\n')
    } else {
      this.stderrLines.push(line + '\n')
    }
    this.emit('output', line + '\n')
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
      if (key.startsWith('MDJAM_') || key === '_MDJAM_CAP') continue

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
