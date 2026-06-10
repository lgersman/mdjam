import matter from 'gray-matter'

export interface Prerequisites {
  tools?: string[]
  env?: string[]
}

export interface DocumentFrontmatter {
  title?: string
  prerequisites?: Prerequisites
  setup?: string
  teardown?: string
  defaults?: Record<string, string>
}

export interface ParsedDocument {
  frontmatter: DocumentFrontmatter
  body: string
}

export function parseFrontmatter(content: string): ParsedDocument {
  try {
    const result = matter(content)
    return {
      frontmatter: (result.data ?? {}) as DocumentFrontmatter,
      body: result.content,
    }
  } catch {
    return { frontmatter: {}, body: content }
  }
}
