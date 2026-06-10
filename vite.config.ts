import { defineConfig } from 'vite-plus'

export default defineConfig({
  run: {
    tasks: {
      start: {
        command: 'bun dist/cli.js',
        dependsOn: ['build'],
      },
    },
  },
  build: {
    lib: {
      entry: './src/cli.ts',
      formats: ['es'],
      fileName: () => 'cli.js',
    },
    target: 'node24',
    sourcemap: true,
    rollupOptions: {
      external: (id) => !id.startsWith('.') && !id.startsWith('/'),
      output: {
        banner: '#!/usr/bin/env bun',
      },
    },
  },
})
