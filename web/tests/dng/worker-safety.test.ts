// The web app's design makes src/dng/ the one module that must run unchanged inside a
// Web Worker, with no bundler and no dependencies: DataView, Uint8Array, TextEncoder
// and TextDecoder only. Nothing else enforces that. tsconfig.json puts DOM and @types/node
// in `lib` and `types` for the whole project, so a reference to `document`, `DOMParser`
// or a Node built-in in here would type-check clean, pass every other test, and only
// fail once the code actually ran off the main thread.

import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const dngDir = resolve(dirname(fileURLToPath(import.meta.url)), '../../src/dng');
const files = readdirSync(dngDir).filter((f) => f.endsWith('.ts')).sort();

/** Drops comments, so a banned name merely mentioned in prose is not a failure. */
function code(src: string): string {
  return src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '');
}

const BANNED = ['DOMParser', 'document', 'window', 'Buffer', 'process', 'require(', 'node:'];

describe('src/dng/ stays worker-safe', () => {
  it('covers all four modules', () => {
    expect(files).toEqual(['identity.ts', 'patch.ts', 'tiff.ts', 'xmp.ts']);
  });

  for (const file of files) {
    const src = code(readFileSync(join(dngDir, file), 'utf8'));

    it(`${file} imports nothing but its siblings`, () => {
      const importRe = /\bfrom\s*['"]([^'"]+)['"]|\bimport\s*['"]([^'"]+)['"]/g;
      const specifiers = [...src.matchAll(importRe)].map((m) => m[1] ?? m[2]!);
      for (const spec of specifiers) {
        expect(spec.startsWith('./'), `${file} imports '${spec}', which is not a sibling module`).toBe(true);
      }
    });

    it(`${file} touches no main-thread or Node global`, () => {
      for (const name of BANNED) {
        expect(src.includes(name), `${file} references '${name}'`).toBe(false);
      }
    });
  }
});
