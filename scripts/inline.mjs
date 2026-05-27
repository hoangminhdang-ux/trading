#!/usr/bin/env node
// Reads frontend/index.html (single-file source) and wraps it as src/frontend.ts
// for Cloudflare Worker deployment.
//
// To edit UI: edit frontend/index.html directly, then run: npm run deploy
// No Astro/npm build step needed.
import fs from 'fs';

function inline(srcRel, outRel, exportName) {
  const srcPath = new URL(srcRel, import.meta.url).pathname;
  const outPath = new URL(outRel, import.meta.url).pathname;
  const html = fs.readFileSync(srcPath, 'utf8');
  const ts   = `export const ${exportName}: string = ${JSON.stringify(html)};\n`;
  fs.writeFileSync(outPath, ts);
  console.log(`[inline] wrote ${outRel} (${(ts.length / 1024).toFixed(1)} KB)`);
}

inline('../frontend/index.html',        '../src/frontend.ts',    'frontendHtml');
inline('../scripts/compare-keys.html',  '../src/compareKeys.ts', 'compareKeysHtml');
