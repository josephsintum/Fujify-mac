// Locates the real-DNG fixture and the shared tools. Everything here is optional:
// fixtures/ is gitignored and sample.dng is built locally by tools/fetch-fixtures.sh,
// so tests that need them skip rather than fail on a fresh clone or in CI.

import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
export const repoRoot = resolve(here, '../../..');
export const sampleDng = resolve(repoRoot, 'fixtures/sample.dng');
export const verifyScript = resolve(repoRoot, 'tools/verify-dng.sh');
export const exiftoolConfig = resolve(repoRoot, 'tools/exiftool-fujify.config');

export const hasFixture = existsSync(sampleDng);

export const hasExiftool = (() => {
  try {
    execFileSync('exiftool', ['-ver'], { stdio: 'pipe' });
    return true;
  } catch {
    return false;
  }
})();

export const goldenReady = hasFixture && hasExiftool;

export const skipReason = !hasFixture
  ? 'fixtures/sample.dng is missing — run tools/fetch-fixtures.sh'
  : !hasExiftool
    ? 'exiftool is not on PATH — brew install exiftool'
    : '';

/** Reads tags as exiftool sees them, with the Fujify namespace config loaded. */
export function exiftoolJson(file: string): Record<string, unknown> {
  const out = execFileSync(
    'exiftool',
    ['-config', exiftoolConfig, '-j', '-G1', '-a', '-s', file],
    { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 },
  );
  return (JSON.parse(out) as Record<string, unknown>[])[0]!;
}
