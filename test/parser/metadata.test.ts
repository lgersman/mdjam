import { describe, it, expect } from 'vite-plus/test'
import { parseFenceMetadata, extractFenceNodes } from '../../src/parser/metadata.js'

describe('parseFenceMetadata', () => {
  it('returns null metadata when no comment block', () => {
    const body = 'echo hello\n'
    const result = parseFenceMetadata(body)
    expect(result.metadata).toBeNull()
    expect(result.cleanBody).toBe(body)
    expect(result.parseError).toBeUndefined()
  })

  it('parses a full metadata block', () => {
    const body = `# ---
# id: fetch-token
# description: Retrieve auth token
# auto: false
# inputs:
#   API_HOST:
#     description: Base URL
#     default: https://api.example.com
#     readonly: false
# outputs: [API_TOKEN]
# depends: []
# ---
TOKEN=$(curl -sf "$API_HOST/auth/token")
`
    const result = parseFenceMetadata(body)
    expect(result.metadata).not.toBeNull()
    expect(result.metadata!.id).toBe('fetch-token')
    expect(result.metadata!.description).toBe('Retrieve auth token')
    expect(result.metadata!.auto).toBe(false)
    expect(result.metadata!.inputs?.API_HOST?.default).toBe('https://api.example.com')
    expect(result.metadata!.outputs).toEqual(['API_TOKEN'])
    expect(result.metadata!.depends).toEqual([])
    expect(result.cleanBody).toBe('TOKEN=$(curl -sf "$API_HOST/auth/token")\n')
  })

  it('returns parseError on malformed YAML', () => {
    const body = `# ---
# id: [invalid yaml: {
# ---
echo hi
`
    const result = parseFenceMetadata(body)
    expect(result.parseError).toBeDefined()
    expect(result.cleanBody).toBe('echo hi\n')
  })

  it('handles metadata with only id field', () => {
    const body = `# ---
# id: simple
# ---
echo simple
`
    const result = parseFenceMetadata(body)
    expect(result.metadata?.id).toBe('simple')
    expect(result.cleanBody).toBe('echo simple\n')
  })
})

describe('extractFenceNodes', () => {
  it('extracts fence nodes with ids and deps', () => {
    const body = `
\`\`\`bash
# ---
# id: step1
# depends: []
# ---
echo step1
\`\`\`

Some text.

\`\`\`bash
# ---
# id: step2
# depends: [step1]
# ---
echo step2
\`\`\`
`
    const nodes = extractFenceNodes(body)
    expect(nodes).toHaveLength(2)
    expect(nodes[0].id).toBe('step1')
    expect(nodes[0].depends).toEqual([])
    expect(nodes[1].id).toBe('step2')
    expect(nodes[1].depends).toEqual(['step1'])
  })

  it('assigns auto-ids to fences without metadata', () => {
    const body = `\`\`\`bash\necho hello\n\`\`\``
    const nodes = extractFenceNodes(body)
    expect(nodes).toHaveLength(1)
    expect(nodes[0].id).toBe('__fence_0')
    expect(nodes[0].depends).toEqual([])
  })
})
