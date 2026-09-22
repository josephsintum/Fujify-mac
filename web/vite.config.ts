// vitest/config, not vite — the `test` key below is not part of vite's own schema.
import { defineConfig } from 'vitest/config';
import { svelte } from '@sveltejs/vite-plugin-svelte';

export default defineConfig({
  plugins: [svelte()],
  // Root-relative, which is what `vite preview` and a custom domain both want. A
  // GitHub Pages project site is served under /<repo>/ instead, so the Pages build
  // passes VITE_BASE (e.g. VITE_BASE=/Fujify-mac/) rather than that being the default
  // everyone else has to override.
  base: process.env.VITE_BASE ?? '/',
  test: {
    include: ['tests/**/*.test.ts'],
    environment: 'node',
  },
});
