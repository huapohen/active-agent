import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';
import tailwind from '@tailwindcss/vite';

export default defineConfig({
  plugins: [react(), tailwind()],
  base: './',
  server: {
    proxy: {
      // One explicit local migration destination. No caller-controlled target,
      // arbitrary URL proxying, or production authorization downgrade.
      '/legacy/api/im': { target: 'http://127.0.0.1:3218', changeOrigin: true, rewrite: path => path.replace(/^\/legacy/, '') },
    },
  },
  test: { environment: 'jsdom', restoreMocks: true, include: ['src/**/*.test.ts', 'src/**/*.test.tsx'] },
});
