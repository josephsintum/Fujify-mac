// TIFF/DNG structure reading. Knows about bytes and IFD entries, nothing about
// cameras. Browser-only APIs: DataView, Uint8Array, TextDecoder.

export const TAG = {
  Make: 0x010f,
  Model: 0x0110,
  XMP: 0x02bc,
  DNGVersion: 0xc612,
  UniqueCameraModel: 0xc614,
} as const;

/** The file is not something we can safely patch. Surfaced to the user as `notADng`. */
export class NotADngError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'NotADngError';
  }
}

export interface TiffHeader {
  littleEndian: boolean;
  ifd0Offset: number;
}

export interface IfdEntry {
  tag: number;
  type: number;
  /** Number of values of `type`, not bytes. For ASCII and BYTE these coincide. */
  count: number;
  /** Offset of the 12-byte entry record itself. */
  entryOffset: number;
  /** Where the value bytes live. For inline values this is `entryOffset + 8`. */
  dataOffset: number;
  byteLength: number;
  inline: boolean;
}

export interface Ifd {
  offset: number;
  count: number;
  entries: Map<number, IfdEntry>;
  nextIfdPointerOffset: number;
}

/** Bytes per value for each TIFF type, indexed by type code. Unknown types count as 1. */
const TYPE_SIZE: Record<number, number> = {
  1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4,
};

export function view(buf: Uint8Array): DataView {
  return new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
}

export function readHeader(buf: Uint8Array): TiffHeader {
  if (buf.byteLength < 8) throw new NotADngError('file is too small to be a DNG');
  const order = String.fromCharCode(buf[0]!, buf[1]!);
  if (order !== 'II' && order !== 'MM') throw new NotADngError('not a TIFF file');
  const littleEndian = order === 'II';
  const dv = view(buf);
  const magic = dv.getUint16(2, littleEndian);
  // DNG is TIFF 6, always magic 42. BigTIFF (43) is a different container.
  if (magic !== 42) throw new NotADngError(`not a classic TIFF file (magic ${magic})`);
  return { littleEndian, ifd0Offset: dv.getUint32(4, littleEndian) };
}

export function readIfd0(buf: Uint8Array, header: TiffHeader): Ifd {
  const { littleEndian: le, ifd0Offset: offset } = header;
  const dv = view(buf);
  if (offset + 2 > buf.byteLength) throw new NotADngError('IFD0 starts past the end of the file');
  const count = dv.getUint16(offset, le);
  const end = offset + 2 + count * 12 + 4;
  if (end > buf.byteLength) throw new NotADngError('IFD0 runs past the end of the file');

  const entries = new Map<number, IfdEntry>();
  for (let i = 0; i < count; i++) {
    const entryOffset = offset + 2 + i * 12;
    const tag = dv.getUint16(entryOffset, le);
    const type = dv.getUint16(entryOffset + 2, le);
    const valueCount = dv.getUint32(entryOffset + 4, le);
    const byteLength = (TYPE_SIZE[type] ?? 1) * valueCount;
    const inline = byteLength <= 4;
    const dataOffset = inline ? entryOffset + 8 : dv.getUint32(entryOffset + 8, le);
    if (!inline && dataOffset + byteLength > buf.byteLength) {
      throw new NotADngError(`tag 0x${tag.toString(16)} points past the end of the file`);
    }
    // Duplicate tags are malformed; the first wins, which is what exiftool does.
    if (!entries.has(tag)) {
      entries.set(tag, { tag, type, count: valueCount, entryOffset, dataOffset, byteLength, inline });
    }
  }

  return { offset, count, entries, nextIfdPointerOffset: offset + 2 + count * 12 };
}

export function readAscii(buf: Uint8Array, entry: IfdEntry | undefined): string {
  if (!entry) return '';
  let out = '';
  for (let i = 0; i < entry.byteLength; i++) {
    const c = buf[entry.dataOffset + i];
    if (c === undefined || c === 0) break;
    out += String.fromCharCode(c);
  }
  return out;
}
