// Builds valid little- or big-endian DNGs in memory for tests. Deliberately
// independent of src/dng/ — nothing here imports the code under test.

export interface SynthOptions {
  littleEndian?: boolean;
  make?: string;
  model?: string;
  /** null omits the UniqueCameraModel tag entirely. */
  uniqueCameraModel?: string | null;
  /** null omits the XMP tag entirely. */
  xmp?: string | null;
  /** Extra zero bytes after the last value, to exercise odd file lengths. */
  trailingBytes?: number;
}

const TAG_MAKE = 0x010f;
const TAG_MODEL = 0x0110;
const TAG_XMP = 0x02bc;
const TAG_DNG_VERSION = 0xc612;
const TAG_UCM = 0xc614;

/** An XMP packet shaped like Adobe's: header, one rdf:Description, padding, writable trailer. */
export function xmpPacket(padding: number, extra = ''): string {
  const head =
    `<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>\n` +
    `<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Synth 1.0">\n` +
    ` <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n` +
    `  <rdf:Description rdf:about=""\n` +
    `    xmlns:tiff="http://ns.adobe.com/tiff/1.0/"\n` +
    `   tiff:Make="SONY">\n` +
    extra +
    `  </rdf:Description>\n` +
    ` </rdf:RDF>\n` +
    `</x:xmpmeta>\n`;
  return head + ' '.repeat(padding) + `<?xpacket end='w'?>`;
}

export function synthDng(opts: SynthOptions = {}): Uint8Array {
  const le = opts.littleEndian ?? true;
  const make = opts.make ?? 'SONY';
  const model = opts.model ?? 'ILCE-7S';
  const ucm = opts.uniqueCameraModel === undefined ? 'Sony ILCE-7S' : opts.uniqueCameraModel;
  const xmp = opts.xmp === undefined ? xmpPacket(4096) : opts.xmp;

  const enc = new TextEncoder();
  const fields: { tag: number; type: number; count: number; bytes: Uint8Array }[] = [];
  const ascii = (tag: number, s: string) => {
    const bytes = enc.encode(s + '\0');
    fields.push({ tag, type: 2, count: bytes.length, bytes });
  };

  ascii(TAG_MAKE, make);
  ascii(TAG_MODEL, model);
  fields.push({ tag: TAG_DNG_VERSION, type: 1, count: 4, bytes: new Uint8Array([1, 6, 0, 0]) });
  if (ucm !== null) ascii(TAG_UCM, ucm);
  if (xmp !== null) {
    const bytes = enc.encode(xmp);
    fields.push({ tag: TAG_XMP, type: 1, count: bytes.length, bytes });
  }
  fields.sort((a, b) => a.tag - b.tag);

  const ifdOffset = 8;
  let dataAt = ifdOffset + 2 + fields.length * 12 + 4;
  const placed = fields.map((f) => {
    if (f.bytes.length <= 4) return { f, at: -1 };
    const at = dataAt;
    dataAt += f.bytes.length + (f.bytes.length & 1);
    return { f, at };
  });

  const out = new Uint8Array(dataAt + (opts.trailingBytes ?? 0));
  const dv = new DataView(out.buffer);
  out[0] = out[1] = le ? 0x49 : 0x4d;
  dv.setUint16(2, 42, le);
  dv.setUint32(4, ifdOffset, le);
  dv.setUint16(ifdOffset, fields.length, le);

  placed.forEach(({ f, at }, i) => {
    const e = ifdOffset + 2 + i * 12;
    dv.setUint16(e, f.tag, le);
    dv.setUint16(e + 2, f.type, le);
    dv.setUint32(e + 4, f.count, le);
    if (at < 0) out.set(f.bytes, e + 8);
    else {
      dv.setUint32(e + 8, at, le);
      out.set(f.bytes, at);
    }
  });
  dv.setUint32(ifdOffset + 2 + fields.length * 12, 0, le);
  return out;
}
