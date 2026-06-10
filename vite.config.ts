import { defineConfig } from 'vite'
import { resolve } from 'path'

export default defineConfig({
  build: {
    lib: {
      entry: resolve(__dirname, 'src/cli.ts'),
      formats: ['es'],
      fileName: () => 'cli.js',
    },
    target: 'node24',
    outDir: 'dist',
    sourcemap: true,
    rollupOptions: {
      external: [
        /^node:/,
        /^@opentui\//,
        'gray-matter',
        'commander',
        'js-yaml',
      ],
      output: {
        banner: '#!/usr/bin/env node',
      },
    },
  },
})
