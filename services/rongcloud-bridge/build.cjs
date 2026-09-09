'use strict';
const {build}=require('esbuild');
const {mkdir,copyFile}=require('node:fs/promises');
const path=require('node:path');
(async()=>{
 await mkdir(path.join(__dirname,'dist'),{recursive:true});
 await build({entryPoints:[path.join(__dirname,'preload.cjs')],outfile:path.join(__dirname,'dist/preload.cjs'),bundle:true,platform:'node',format:'cjs',external:['electron'],target:'node22'});
 await build({entryPoints:[path.join(__dirname,'preload-web.cjs')],outfile:path.join(__dirname,'dist/preload-web.cjs'),bundle:true,platform:'node',format:'cjs',external:['electron'],target:'node22'});
 await build({entryPoints:[path.join(__dirname,'worker.ts')],outfile:path.join(__dirname,'dist/worker.js'),bundle:true,platform:'browser',format:'iife',target:'chrome140',external:['path']});
 await copyFile(path.join(__dirname,'index.html'),path.join(__dirname,'dist/index.html'));
})().catch(()=>{console.error('bridge_build_failed');process.exitCode=1;});
