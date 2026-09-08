'use strict';
const { build } = require('esbuild');
const { mkdir, copyFile } = require('node:fs/promises');
const path = require('node:path');
const base = path.resolve(__dirname, '..');
(async () => {
  await mkdir(path.join(base, 'dist'), { recursive: true });
  await Promise.all(['preload', 'transport-preload'].map(name => build({ entryPoints: [path.join(base, 'src', `${name}.cjs`)], outfile: path.join(base, 'dist', `${name}.cjs`), bundle: true, platform: 'node', format: 'cjs', external: ['electron'], target: 'node22' })));
  // The SDK has an unreachable browser-side Node upload branch. Keep it
  // external, as Vite does; this receive-only worker exposes no file upload.
  await build({ entryPoints: [path.join(base, 'src/transport-worker.ts')], outfile: path.join(base, 'dist/transport-worker.js'), bundle: true, platform: 'browser', format: 'iife', target: 'chrome140', external: ['path'] });
  await copyFile(path.join(base, 'src/transport.html'), path.join(base, 'dist/index.html'));
})().catch(() => { console.error('Desktop preload build failed'); process.exitCode = 1; });
