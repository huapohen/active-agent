'use strict';
const { spawnSync, spawn } = require('node:child_process');
const path = require('node:path');
const base = path.resolve(__dirname, '..');
const built = spawnSync(process.execPath, [path.join(__dirname, 'build-preload.cjs')], { stdio: 'inherit' });
if (built.status !== 0) process.exit(built.status || 1);
let electron;
try { electron = require('electron'); } catch { console.error('Electron 二进制尚未安装。请按 apps/desktop/README.md 检查下载线路后安装。'); process.exit(1); }
const child = spawn(electron, [base], { stdio: 'inherit', env: { ...process.env, RENJI_WEB_DEV_URL: process.env.RENJI_WEB_DEV_URL || 'http://127.0.0.1:5173' } });
child.on('exit', code => { process.exitCode = code || 0; });
