// vitest/config, not vite — the `test` key below is not part of vite's own schema.
import { defineConfig } from 'vitest/config';
import { svelte } from '@sveltejs/vite-plugin-svelte';

export default defineConfig({
  plugins: [svelte()],
  // GitHub Pages serves this repo at /Fujify-mac/; overridden in CI if that changes.
  base: process.env.VITE_BASE ?? '/',
  test: {
    include: ['tests/**/*.test.ts'],
    environment: 'node',
  },
});
