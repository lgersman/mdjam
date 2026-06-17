import yaml from 'js-yaml'

export interface InputSpec {
  description?: string
  default?: string
  readonly?: boolean
}

export interface FenceMetadata {
  id?: string
  description?: string
  auto?: boolean
  interactive?: boolean
  inputs?: Record<string, InputSpec>
  outputs?: string[]
  depends?: string[]
}

export interface ParsedFence {
  metadata: FenceMetadata | null
  cleanBody: string
  parseError?: string
}

// Matches a leading # --- ... # --- comment block
const METADATA_BLOCK_RE = /^# ---\n((?:#[^\n]*\n)*)# ---\n/

export function parseFenceMetadata(fenceBody: string): ParsedFence {
  const match = fenceBody.match(METADATA_BLOCK_RE)
  if (!match) {
    return { metadata: null, cleanBody: fenceBody }
  }

  const yamlSource = match[1]
    .split('\n')
    .map(line => line.replace(/^#[ ]?/, ''))
    .join('\n')

  const cleanBody = fenceBody.slice(match[0].length)

  try {
    const parsed = yaml.load(yamlSource)
    if (parsed === null || typeof parsed !== 'object') {
      return { metadata: null, cleanBody }
    }
    return { metadata: parsed as FenceMetadata, cleanBody }
  } catch (err) {
    return {
      metadata: null,
      cleanBody,
      parseError: err instanceof Error ? err.message : String(err),
    }
  }
}

/** Extract bare FenceNode info (id, depends) from a markdown body for graph building. */
export function extractFenceNodes(markdownBody: string): { id: string; depends: string[] }[] {
  const nodes: { id: string; depends: string[] }[] = []
  // Match fenced code blocks with bash/sh language
  const fenceRe = /^```(?:bash|sh)\n([\s\S]*?)^```/gm
  let idx = 0
  let match: RegExpExecArray | null

  while ((match = fenceRe.exec(markdownBody)) !== null) {
    const body = match[1]
    const { metadata } = parseFenceMetadata(body)
    const id = metadata?.id ?? `__fence_${idx}`
    const depends = metadata?.depends ?? []
    nodes.push({ id, depends })
    idx++
  }

  return nodes
}
