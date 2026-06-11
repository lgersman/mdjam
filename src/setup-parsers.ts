import { addDefaultParsers } from '@opentui/core'
import { createRequire } from 'node:module'
import { dirname, join } from 'node:path'

const _require = createRequire(import.meta.url)
const bashPkgDir = dirname(_require.resolve('tree-sitter-bash/package.json'))
addDefaultParsers([{
  filetype: 'bash',
  aliases: ['sh', 'shell'],
  wasm: join(bashPkgDir, 'tree-sitter-bash.wasm'),
  queries: {
    highlights: [join(bashPkgDir, 'queries/highlights.scm')],
  },
}])
