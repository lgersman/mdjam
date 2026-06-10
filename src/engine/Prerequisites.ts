import { execSync } from 'node:child_process'
import type { Prerequisites } from '../parser/frontmatter.js'

export interface PrerequisiteResult {
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

export function checkPrerequisites(prereqs: Prerequisites): PrerequisiteResult {
  const failed: string[] = []

  for (const tool of prereqs.tools ?? []) {
    if (!toolExists(tool)) failed.push(`tool '${tool}' not found in PATH`)
  }

  for (const envVar of prereqs.env ?? []) {
    if (process.env[envVar] === undefined) failed.push(`env var $${envVar} is not set`)
  }

  return { failed }
}
