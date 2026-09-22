import { describe, expect, it } from 'vitest';
import { NotADngError } from '../../src/dng/tiff';
import { hasStash, readDng, readXmpProperty } from '../../src/dng/identity';
import { synthDng, xmpPacket } from '../helpers/synth';

const TAGGED = `   <photoshop:CameraProfiles>
    <rdf:Seq>
     <rdf:li rdf:parseType="Resource">
      <stCamera:CameraRawProfile>True</stCamera:CameraRawProfile>
      <stCamera:Make>FUJIFILM</stCamera:Make>
      <stCamera:Model>X-T5</stCamera:Model>
      <stCamera:UniqueCameraModel>Fujifilm X-T5</stCamera:UniqueCameraModel>
     </rdf:li>
    </rdf:Seq>
   </photoshop:CameraProfiles>
   <fujify:OriginalMake>SONY</fujify:OriginalMake>
   <fujify:OriginalModel>ILCE-7S</fujify:OriginalModel>
   <fujify:OriginalUniqueCameraModel>Sony ILCE-7S</fujify:OriginalUniqueCameraModel>
   <fujify:Version>1</fujify:Version>
   <fujify:TargetModel>X-T5</fujify:TargetModel>
`;

const TAGGED_WITH_NESTED_CHILD = `   <photoshop:CameraProfiles>
    <rdf:Seq>
     <rdf:li rdf:parseType="Resource">
      <stCamera:Embedded rdf:parseType="Resource"/>
      <stCamera:CameraRawProfile>True</stCamera:CameraRawProfile>
      <stCamera:Make>FUJIFILM</stCamera:Make>
      <stCamera:Model>X-T5</stCamera:Model>
      <stCamera:UniqueCameraModel>Fujifilm X-T5</stCamera:UniqueCameraModel>
     </rdf:li>
    </rdf:Seq>
   </photoshop:CameraProfiles>
   <fujify:OriginalMake>SONY</fujify:OriginalMake>
   <fujify:OriginalModel>ILCE-7S</fujify:OriginalModel>
   <fujify:OriginalUniqueCameraModel>Sony ILCE-7S</fujify:OriginalUniqueCameraModel>
   <fujify:Version>1</fujify:Version>
   <fujify:TargetModel>X-T5</fujify:TargetModel>
`;

describe('readDng', () => {
  it('reads the camera identity from IFD0', () => {
    const info = readDng(synthDng());
    expect(info.identity).toEqual({ make: 'SONY', model: 'ILCE-7S', uniqueCameraModel: 'Sony ILCE-7S' });
  });

  it('reports empty profile tags and an empty stash for an untouched file', () => {
    const info = readDng(synthDng());
    expect(info.profiles).toEqual({ make: '', model: '', uniqueCameraModel: '', cameraRawProfile: '' });
    expect(info.stash.originalMake).toBe('');
    expect(hasStash(info)).toBe(false);
  });

  it('reads the profile tags and stash out of a file Fujify already tagged', () => {
    const info = readDng(synthDng({ xmp: xmpPacket(512, TAGGED), uniqueCameraModel: 'Fujifilm X-T5' }));
    expect(info.profiles).toEqual({
      make: 'FUJIFILM', model: 'X-T5', uniqueCameraModel: 'Fujifilm X-T5', cameraRawProfile: 'True',
    });
    expect(info.stash).toEqual({
      originalMake: 'SONY',
      originalModel: 'ILCE-7S',
      originalUniqueCameraModel: 'Sony ILCE-7S',
      targetModel: 'X-T5',
      version: '1',
    });
    expect(hasStash(info)).toBe(true);
  });

  it('reports a null packet when the file has no XMP', () => {
    const info = readDng(synthDng({ xmp: null }));
    expect(info.xmpPacket).toBeNull();
    expect(info.profiles.make).toBe('');
  });

  it('rejects a TIFF with no DNGVersion tag', () => {
    const buf = synthDng();
    // Turn the DNGVersion tag into an unknown one, leaving the file otherwise valid.
    const dv = new DataView(buf.buffer);
    for (let i = 0; i < dv.getUint16(8, true); i++) {
      const e = 10 + i * 12;
      if (dv.getUint16(e, true) === 0xc612) dv.setUint16(e, 0xdead, true);
    }
    expect(() => readDng(buf)).toThrow(/not a DNG/);
    expect(() => readDng(buf)).toThrow(NotADngError);
  });

  it('works in big-endian files', () => {
    const info = readDng(synthDng({ littleEndian: false, make: 'CANON', model: 'EOS R6' }));
    expect(info.identity.make).toBe('CANON');
    expect(info.identity.model).toBe('EOS R6');
  });

  it('reads profile tags when rdf:li contains nested self-closing children', () => {
    const info = readDng(synthDng({ xmp: xmpPacket(512, TAGGED_WITH_NESTED_CHILD), uniqueCameraModel: 'Fujifilm X-T5' }));
    expect(info.profiles.make).toBe('FUJIFILM');
    expect(info.profiles.model).toBe('X-T5');
    expect(info.profiles.uniqueCameraModel).toBe('Fujifilm X-T5');
  });
});

describe('readXmpProperty', () => {
  it('reads an element', () => {
    expect(readXmpProperty('<a:b>value</a:b>', 'a:b')).toBe('value');
  });

  it('reads a double-quoted attribute', () => {
    expect(readXmpProperty('<rdf:Description a:b="value">', 'a:b')).toBe('value');
  });

  it('reads a single-quoted attribute, which is what exiftool writes', () => {
    expect(readXmpProperty("<rdf:Description a:b='value'>", 'a:b')).toBe('value');
  });

  it('decodes XML entities', () => {
    expect(readXmpProperty('<a:b>M&amp;M &lt;x&gt;</a:b>', 'a:b')).toBe('M&M <x>');
  });

  it('returns an empty string when the property is absent', () => {
    expect(readXmpProperty('<a:other>value</a:other>', 'a:b')).toBe('');
  });

  it('does not match a property whose name merely ends with the one asked for', () => {
    expect(readXmpProperty('<x:NotMake>wrong</x:NotMake>', 'x:Make')).toBe('');
  });
});
