import { describe, expect, it } from 'vitest';
import { NotADngError, TAG, readAscii, readHeader, readIfd0 } from '../../src/dng/tiff';
import { synthDng, xmpPacket } from '../helpers/synth';

describe('readHeader', () => {
  it('reads a little-endian header', () => {
    expect(readHeader(synthDng())).toEqual({ littleEndian: true, ifd0Offset: 8 });
  });

  it('reads a big-endian header', () => {
    expect(readHeader(synthDng({ littleEndian: false }))).toEqual({ littleEndian: false, ifd0Offset: 8 });
  });

  it('rejects a file that is not TIFF', () => {
    expect(() => readHeader(new TextEncoder().encode('not a tiff at all'))).toThrow(NotADngError);
  });

  it('rejects BigTIFF', () => {
    const buf = synthDng();
    new DataView(buf.buffer).setUint16(2, 43, true);
    expect(() => readHeader(buf)).toThrow(/magic 43/);
  });

  it('rejects a truncated file', () => {
    expect(() => readHeader(new Uint8Array(4))).toThrow(NotADngError);
  });
});

describe('readIfd0', () => {
  it('finds every tag it was given, in either byte order', () => {
    for (const littleEndian of [true, false]) {
      const buf = synthDng({ littleEndian });
      const ifd = readIfd0(buf, readHeader(buf));
      expect(ifd.entries.has(TAG.Make)).toBe(true);
      expect(ifd.entries.has(TAG.Model)).toBe(true);
      expect(ifd.entries.has(TAG.DNGVersion)).toBe(true);
      expect(ifd.entries.has(TAG.UniqueCameraModel)).toBe(true);
      expect(ifd.entries.has(TAG.XMP)).toBe(true);
      expect(ifd.count).toBe(5);
    }
  });

  it('reports an out-of-line entry with its real data offset', () => {
    const buf = synthDng();
    const ifd = readIfd0(buf, readHeader(buf));
    const xmp = ifd.entries.get(TAG.XMP)!;
    expect(xmp.inline).toBe(false);
    expect(xmp.dataOffset).toBeGreaterThan(ifd.offset);
    expect(xmp.byteLength).toBe(xmp.count);
  });

  it('reports a 4-byte value as inline, stored in the entry itself', () => {
    const buf = synthDng();
    const ifd = readIfd0(buf, readHeader(buf));
    const version = ifd.entries.get(TAG.DNGVersion)!;
    expect(version.inline).toBe(true);
    expect(version.dataOffset).toBe(version.entryOffset + 8);
    expect(Array.from(buf.subarray(version.dataOffset, version.dataOffset + 4))).toEqual([1, 6, 0, 0]);
  });

  it('points at the next-IFD pointer just past the entries', () => {
    const buf = synthDng();
    const ifd = readIfd0(buf, readHeader(buf));
    expect(ifd.nextIfdPointerOffset).toBe(ifd.offset + 2 + ifd.count * 12);
  });

  it('rejects an IFD0 offset past the end of the file', () => {
    const buf = synthDng();
    new DataView(buf.buffer).setUint32(4, buf.length + 100, true);
    expect(() => readIfd0(buf, readHeader(buf))).toThrow(NotADngError);
  });
});

describe('readAscii', () => {
  it('reads a string and stops at the NUL', () => {
    const buf = synthDng({ make: 'NIKON CORPORATION' });
    const ifd = readIfd0(buf, readHeader(buf));
    expect(readAscii(buf, ifd.entries.get(TAG.Make))).toBe('NIKON CORPORATION');
  });

  it('returns an empty string for a missing entry', () => {
    const buf = synthDng({ uniqueCameraModel: null });
    const ifd = readIfd0(buf, readHeader(buf));
    expect(readAscii(buf, ifd.entries.get(TAG.UniqueCameraModel))).toBe('');
  });

  it('reads the XMP packet back byte for byte', () => {
    const packet = xmpPacket(128);
    const buf = synthDng({ xmp: packet });
    const ifd = readIfd0(buf, readHeader(buf));
    const e = ifd.entries.get(TAG.XMP)!;
    expect(new TextDecoder().decode(buf.subarray(e.dataOffset, e.dataOffset + e.byteLength))).toBe(packet);
  });
});
