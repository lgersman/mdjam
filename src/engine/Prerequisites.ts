import { execSync } from 'node:child_process'
import type { Prerequisites } from '../parser/frontmatter.js'

export interface PrerequisiteResult {
  passed: string[]
  failed: string[]
}

function toolExists(name: string): boolean {
  try {
    execSync(`command -v ${name}`, { stdio: 'ignore' })
    return true
  } catch {
    return false
  }
}

export async function checkPrerequisites(prereqs: Prerequisites): Promise<PrerequisiteResult> {
  const passed: string[] = []
  const failed: string[] = []

  for (const tool of prereqs.tools ?? []) {
    if (toolExists(tool)) {
      passed.push(`tool:${tool}`)
    } else {
      failed.push(`tool '${tool}' not found in PATH`)
    }
  }

  for (const envVar of prereqs.env ?? []) {
    if (process.env[envVar] !== undefined) {
      passed.push(`env:${envVar}`)
    } else {
      failed.push(`env var $${envVar} is not set`)
    }
  }

  return { passed, failed }
}
