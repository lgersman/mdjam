import { defineConfig } from 'vite-plus'

export default defineConfig({
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
        banner: '#!/usr/bin/env node',
      },
    },
  },
})
