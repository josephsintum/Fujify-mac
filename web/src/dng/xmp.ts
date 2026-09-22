// Rewrites XMP packet text to carry the Fujify camera identity, and fits the
// result into an exact byte length. Pure strings and bytes; no TIFF knowledge.
//
// The four CameraProfiles* tags of PIPELINE-CONTRACT.md §3.1 are not binary TIFF
// tags at all: exiftool flattens them into a photoshop:CameraProfiles structure
// here. The stash of §3.2 is a custom namespace in the same packet.

import type { CameraIdentity } from './identity';

export interface TargetCamera {
  make: string;
  model: string;
  uniqueCameraModel: string;
}

/** Exactly what exiftool writes. A different URI is a different tag. */
export const NS = {
  photoshop: 'http://ns.adobe.com/photoshop/1.0/',
  stCamera: 'http://ns.adobe.com/photoshop/1.0/camera-profile',
  fujify: 'https://josephsintum.dev/ns/fujify/1.0/',
} as const;

const TRAILER = "<?xpacket end='w'?>";

/** A minimal packet to build on when the DNG carries no XMP tag at all. */
export const EMPTY_PACKET =
  `<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>\n` +
  `<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Fujify">\n` +
  ` <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n` +
  `  <rdf:Description rdf:about="">\n` +
  `  </rdf:Description>\n` +
  ` </rdf:RDF>\n` +
  `</x:xmpmeta>\n` +
  TRAILER;

/**
 * The index of the `>` that really ends the tag starting at `from`, or -1. A plain
 * indexOf('>') is wrong: `>` is legal unescaped inside an attribute value, so it can
 * stop early and hand back a truncated open tag.
 */
function tagEnd(s: string, from: number): number {
  let quote = '';
  for (let i = from; i < s.length; i++) {
    const c = s[i]!;
    if (quote) {
      if (c === quote) quote = '';
      continue;
    }
    if (c === '"' || c === "'") quote = c;
    else if (c === '>') return i;
  }
  return -1;
}

export function encodeEntities(s: string): string {
  return s
    // C0 controls other than tab/LF/CR are outside XML 1.0's Char production and have
    // no escape, so a strict parser rejects the WHOLE packet — losing the file's crs
    // develop settings, xmpMM history, ratings and keywords along with our own block.
    // readAscii passes any non-NUL byte through, so a stray 0x0B in the source Make
    // reaches here. Dropping it is the only representable choice.
    .replace(/[\x00-\x08\x0B\x0C\x0E-\x1F]/g, '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/**
 * Returns the new packet's body (everything up to and including </x:xmpmeta>) and
 * its trailer. Padding is not this function's business — see fitPacket/freshPacket.
 *
 * `keepStash` is the §3.2 rule: a file processed before keeps the identity it was
 * born with, rather than having the already-faked one stashed over it.
 */
export function rewriteXmp(
  oldPacket: string,
  target: TargetCamera,
  original: CameraIdentity,
  keepStash: boolean,
): { body: string; trailer: string } {
  const metaClose = '</x:xmpmeta>';
  const metaEnd = oldPacket.lastIndexOf(metaClose);
  if (metaEnd < 0) throw new Error('XMP packet has no </x:xmpmeta>');

  const trailerAt = oldPacket.lastIndexOf('<?xpacket end');
  const trailer = trailerAt > metaEnd ? oldPacket.slice(trailerAt) : TRAILER;
  let body = oldPacket.slice(0, metaEnd + metaClose.length);

  const descOpen = body.indexOf('<rdf:Description');
  if (descOpen < 0) throw new Error('XMP packet has no rdf:Description');

  // A self-closing Description has nowhere to put child elements; give it a body.
  const descOpenEnd = tagEnd(body, descOpen);
  if (descOpenEnd < 0) throw new Error('XMP packet has an unterminated rdf:Description tag');
  if (body[descOpenEnd - 1] === '/') {
    body = `${body.slice(0, descOpenEnd - 1)}>\n  </rdf:Description>${body.slice(descOpenEnd + 1)}`;
  }

  // Declare only what is missing FROM THIS ELEMENT, so we never duplicate a
  // declaration already on it. XMP allows sibling rdf:Description elements, each
  // scoping its own xmlns declarations to itself — a sibling's declaration does not
  // bind the element we are patching, so the check must be scoped to this element's
  // own open tag, not the whole packet body, or we can emit an element that uses an
  // unbound prefix.
  const openTagEnd = tagEnd(body, descOpen);
  if (openTagEnd < 0) throw new Error('XMP packet has an unterminated rdf:Description tag');
  const openTag = body.slice(descOpen, openTagEnd + 1);

  // An attribute-form fujify:TargetModel names the same XMP property as the element we
  // write below. The element-form strip further down cannot see it, so it would survive
  // and the packet would carry the property twice — exiftool then lists both values,
  // the stale one first, which is what a re-tag is supposed to have replaced.
  let newOpenTag = openTag.replace(/\s+fujify:TargetModel\s*=\s*("[^"]*"|'[^']*')/g, '');

  let decls = '';
  for (const [prefix, uri] of Object.entries(NS)) {
    if (!new RegExp(`xmlns:${prefix}\\s*=`).test(newOpenTag)) decls += `\n    xmlns:${prefix}="${uri}"`;
  }
  if (decls) {
    newOpenTag = '<rdf:Description' + decls + newOpenTag.slice('<rdf:Description'.length);
  }
  if (newOpenTag !== openTag) {
    body = body.slice(0, descOpen) + newOpenTag + body.slice(openTagEnd + 1);
  }

  // Drop the blocks we own before rewriting them, so a re-run replaces rather than repeats.
  body = body.replace(/[ \t]*<photoshop:CameraProfiles>[\s\S]*?<\/photoshop:CameraProfiles>[ \t]*\r?\n?/g, '');
  body = body.replace(/[ \t]*<fujify:TargetModel>[\s\S]*?<\/fujify:TargetModel>[ \t]*\r?\n?/g, '');
  // fujify:Version is re-emitted on every pass (see below), so it is always dropped first.
  body = body.replace(/[ \t]*<fujify:Version>[\s\S]*?<\/fujify:Version>[ \t]*\r?\n?/g, '');
  if (!keepStash) {
    // We are about to write a fresh stash, so any existing one is ours to replace.
    // patch.ts never reaches here with a stash present, but that makes this cheap
    // rather than unnecessary: it is what keeps rewriteXmp idempotent for any caller.
    body = body.replace(
      /[ \t]*<fujify:(Original(?:Make|Model|UniqueCameraModel))>[\s\S]*?<\/fujify:\1>[ \t]*\r?\n?/g,
      '',
    );
  }

  const e = encodeEntities;
  const profiles =
    `   <photoshop:CameraProfiles>\n` +
    `    <rdf:Seq>\n` +
    `     <rdf:li rdf:parseType="Resource">\n` +
    `      <stCamera:CameraRawProfile>True</stCamera:CameraRawProfile>\n` +
    `      <stCamera:Make>${e(target.make)}</stCamera:Make>\n` +
    `      <stCamera:Model>${e(target.model)}</stCamera:Model>\n` +
    `      <stCamera:UniqueCameraModel>${e(target.uniqueCameraModel)}</stCamera:UniqueCameraModel>\n` +
    `     </rdf:li>\n` +
    `    </rdf:Seq>\n` +
    `   </photoshop:CameraProfiles>\n`;

  const stash = keepStash
    ? ''
    : `   <fujify:OriginalMake>${e(original.make)}</fujify:OriginalMake>\n` +
      `   <fujify:OriginalModel>${e(original.model)}</fujify:OriginalModel>\n` +
      `   <fujify:OriginalUniqueCameraModel>${e(original.uniqueCameraModel)}</fujify:OriginalUniqueCameraModel>\n`;

  // Emitted on every pass, re-tag included, because mac/Engine/ExifTool.swift always
  // re-emits it. Keeping the two implementations in step matters the day §3.2's stash
  // shape changes and the version marker is what tells the reader which shape it has.
  const version = `   <fujify:Version>1</fujify:Version>\n`;

  const targetModel = `   <fujify:TargetModel>${e(target.model)}</fujify:TargetModel>\n`;

  const descClose = body.indexOf('</rdf:Description>');
  if (descClose < 0) throw new Error('XMP packet has no </rdf:Description>');
  return {
    body: body.slice(0, descClose) + profiles + stash + version + targetModel + body.slice(descClose),
    trailer,
  };
}

/** Adobe's padding shape: runs of 100 spaces separated by newlines. */
function padding(length: number): Uint8Array {
  const out = new Uint8Array(length).fill(0x20);
  for (let i = 100; i < length; i += 101) out[i] = 0x0a;
  return out;
}

/**
 * Encodes body + padding + trailer into exactly `exactLength` bytes, or returns null
 * when it cannot fit. Fitting exactly is what lets the packet be overwritten in place
 * without touching the IFD entry or moving a single other byte in the file.
 */
export function fitPacket(body: string, trailer: string, exactLength: number): Uint8Array | null {
  const enc = new TextEncoder();
  const bodyBytes = enc.encode(body);
  const trailerBytes = enc.encode(trailer);
  const room = exactLength - bodyBytes.byteLength - trailerBytes.byteLength;
  if (room < 0) return null;

  const out = new Uint8Array(exactLength);
  out.set(bodyBytes, 0);
  out.set(padding(room), bodyBytes.byteLength);
  out.set(trailerBytes, exactLength - trailerBytes.byteLength);
  return out;
}

/** A packet with room to spare, for when the old one cannot hold the new content. */
export function freshPacket(body: string, trailer: string, padBytes = 2048): Uint8Array {
  const enc = new TextEncoder();
  const length = enc.encode(body).byteLength + padBytes + enc.encode(trailer).byteLength;
  // fitPacket cannot fail here: the length was computed from the same strings.
  return fitPacket(body, trailer, length)!;
}
