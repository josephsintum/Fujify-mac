import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { beforeAll, describe, expect, it } from 'vitest';
import { applyPlan, planPatch } from '../src/dng/patch';
import { readDng } from '../src/dng/identity';
import { exiftoolConfig, exiftoolJson, goldenReady, sampleDng, skipReason, verifyScript } from './helpers/fixtures';

const XT5 = { make: 'FUJIFILM', model: 'X-T5', uniqueCameraModel: 'Fujifilm X-T5' };
const X100VI = { make: 'FUJIFILM', model: 'X100VI', uniqueCameraModel: 'Fujifilm X100VI' };

describe.skipIf(!goldenReady)(`golden verification against a real DNG`, () => {
  let dir: string;
  let source: Uint8Array;
  let webOut: string;
  let exiftoolOut: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'fujify-golden-'));
    source = new Uint8Array(readFileSync(sampleDng));

    // Our output.
    webOut = join(dir, 'web.dng');
    writeFileSync(webOut, applyPlan(source, planPatch(source, XT5)));

    // The macOS app's output: the same five tags written by exiftool, per contract §3.1.
    exiftoolOut = join(dir, 'exiftool.dng');
    writeFileSync(exiftoolOut, source);
    execFileSync('exiftool', [
      '-config', exiftoolConfig,
      '-CameraProfilesMake=FUJIFILM',
      '-CameraProfilesModel=X-T5',
      '-CameraProfilesUniqueCameraModel=Fujifilm X-T5',
      '-CameraProfilesCameraRawProfile=True',
      '-UniqueCameraModel=Fujifilm X-T5',
      '-XMP-fujify:OriginalMake=SONY',
      '-XMP-fujify:OriginalModel=ILCE-7S',
      '-XMP-fujify:OriginalUniqueCameraModel=Sony ILCE-7S',
      '-XMP-fujify:TargetModel=X-T5',
      '-XMP-fujify:Version=1',
      '-overwrite_original',
      '-m',
      exiftoolOut,
    ], { stdio: 'pipe' });
  });

  it('passes tools/verify-dng.sh, the contract §12 golden test', () => {
    const out = execFileSync('sh', [verifyScript, webOut], { encoding: 'utf8' });
    expect(out).toContain('carry the FUJIFILM X-T5 identity');
  });

  it('passes verify-dng.sh for the X100VI target too', () => {
    const file = join(dir, 'web-x100vi.dng');
    writeFileSync(file, applyPlan(source, planPatch(source, X100VI)));
    const out = execFileSync('sh', [verifyScript, file, 'X100VI'], { encoding: 'utf8' });
    expect(out).toContain('carry the FUJIFILM X100VI identity');
  });

  it('reads back the same five identity values exiftool wrote', () => {
    const ours = exiftoolJson(webOut);
    const theirs = exiftoolJson(exiftoolOut);
    for (const key of [
      'XMP-photoshop:CameraProfilesMake',
      'XMP-photoshop:CameraProfilesModel',
      'XMP-photoshop:CameraProfilesUniqueCameraModel',
      'XMP-photoshop:CameraProfilesCameraRawProfile',
      'IFD0:UniqueCameraModel',
    ]) {
      expect(ours[key], key).toEqual(theirs[key]);
    }
  });

  it('reads back the same stash exiftool wrote', () => {
    const ours = exiftoolJson(webOut);
    const theirs = exiftoolJson(exiftoolOut);
    for (const key of [
      'XMP-fujify:OriginalMake',
      'XMP-fujify:OriginalModel',
      'XMP-fujify:OriginalUniqueCameraModel',
      'XMP-fujify:TargetModel',
      'XMP-fujify:Version',
    ]) {
      expect(String(ours[key]), key).toEqual(String(theirs[key]));
    }
  });

  it('introduces no new exiftool validation warnings', () => {
    const warnings = (file: string) =>
      execFileSync('exiftool', ['-validate', '-warning', '-a', '-s3', file], { encoding: 'utf8' })
        .trim().split('\n').filter(Boolean).sort();
    expect(warnings(webOut)).toEqual(warnings(sampleDng));
  });

  it('edits the XMP in place, so the file grows by only the longer model string', () => {
    const plan = planPatch(source, XT5);
    expect(plan.relocatedIfd).toBe(false);
    expect(plan.outputLength - source.byteLength).toBeLessThan(64);
  });

  it('leaves the image data untouched — only the two identity locations change', () => {
    const plan = planPatch(source, XT5);
    const out = applyPlan(source, plan);
    const touched = new Set<number>();
    for (const e of plan.edits) for (let i = 0; i < e.bytes.byteLength; i++) touched.add(e.offset + i);
    let differing = 0;
    for (let i = 0; i < source.byteLength; i++) if (out[i] !== source[i]) differing++;
    expect(differing).toBeLessThanOrEqual(touched.size);
    // StripOffsets and the preview pointers must still be where they were.
    expect(out.byteLength).toBe(plan.outputLength);
    const ours = exiftoolJson(webOut);
    const original = exiftoolJson(sampleDng);
    expect(ours['IFD0:StripOffsets']).toEqual(original['IFD0:StripOffsets']);
    expect(ours['SubIFD1:PreviewImageStart']).toEqual(original['SubIFD1:PreviewImageStart']);
  });

  it('survives a second pass to a different target with the stash intact', () => {
    const once = applyPlan(source, planPatch(source, XT5));
    const twice = applyPlan(once, planPatch(once, X100VI));
    const file = join(dir, 'web-twice.dng');
    writeFileSync(file, twice);
    const out = execFileSync('sh', [verifyScript, file, 'X100VI'], { encoding: 'utf8' });
    expect(out).toContain('carry the FUJIFILM X100VI identity');
    expect(readDng(twice).stash.originalUniqueCameraModel).toBe('Sony ILCE-7S');
  });
});

describe.skipIf(goldenReady)('golden verification', () => {
  it('is skipped', () => {
    expect(skipReason).not.toBe('');
    console.warn(`golden tests skipped: ${skipReason}`);
  });
});
