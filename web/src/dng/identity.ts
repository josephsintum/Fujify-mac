// Reads a DNG's camera identity, the CameraProfiles tags Fujify writes, and the
// XMP-fujify stash. Mirrors PIPELINE-CONTRACT.md §3.3: a missing tag is an empty
// string, never an error.

import { type Ifd, type TiffHeader, NotADngError, TAG, readAscii, readHeader, readIfd0 } from './tiff';

export interface CameraIdentity {
  make: string;
  model: string;
  uniqueCameraModel: string;
}

export interface ProfileTags {
  make: string;
  model: string;
  uniqueCameraModel: string;
  cameraRawProfile: string;
}

export interface Stash {
  originalMake: string;
  originalModel: string;
  originalUniqueCameraModel: string;
  targetModel: string;
  version: string;
}

export interface DngInfo {
  header: TiffHeader;
  ifd: Ifd;
  identity: CameraIdentity;
  profiles: ProfileTags;
  stash: Stash;
  /** The raw XMP packet text, or null when the file carries no XMP tag. */
  xmpPacket: string | null;
}

export function decodeEntities(s: string): string {
  return s
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, '&');
}

/** Escapes a qname for use in a RegExp — the ':' is literal, but be safe about the rest. */
function escapeRe(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Reads one XMP property by qualified name, in either of the two forms XMP allows:
 * a child element, or an attribute on rdf:Description. Adobe prefers attributes for
 * simple values; exiftool writes elements. Both must read.
 *
 * Deliberately not a full XML parse: we need five values out of a packet whose exact
 * shape we do not control, and a regex that fails to match yields '' — the same as
 * an absent tag, which is what the contract asks for.
 */
export function readXmpProperty(xml: string, qname: string): string {
  const q = escapeRe(qname);
  const element = xml.match(new RegExp(`<${q}(?:\\s[^>]*)?>([\\s\\S]*?)</${q}>`));
  if (element?.[1] !== undefined) return decodeEntities(element[1].trim());
  // (?<![\w:-]) so stCamera:Make does not match a hypothetical x:stCamera:Make.
  const attr = xml.match(new RegExp(`(?<![\\w:-])${q}\\s*=\\s*("([^"]*)"|'([^']*)')`));
  const value = attr?.[2] ?? attr?.[3];
  return value === undefined ? '' : decodeEntities(value.trim());
}

/** The first rdf:li under photoshop:CameraProfiles, open tag included so attributes read too. */
function firstProfileItem(packet: string): string {
  const block = packet.match(/<photoshop:CameraProfiles>([\s\S]*?)<\/photoshop:CameraProfiles>/);
  if (!block?.[1]) return '';
  // Two alternatives, self-closing tried first. A single lazy terminator of
  // `(?:\/>|<\/rdf:li>)` would stop at the first `/>` in the item — including one
  // belonging to a nested self-closing child — and silently cut every field after
  // it out of the extraction window, so a present stCamera:Make reads as absent.
  const li = block[1].match(/<rdf:li\b[^>]*\/>|<rdf:li\b[^>]*>[\s\S]*?<\/rdf:li>/);
  return li?.[0] ?? '';
}

export function readDng(buf: Uint8Array): DngInfo {
  const header = readHeader(buf);
  const ifd = readIfd0(buf, header);
  if (!ifd.entries.has(TAG.DNGVersion)) {
    throw new NotADngError('this is a TIFF file but not a DNG (no DNGVersion tag)');
  }

  const xmpEntry = ifd.entries.get(TAG.XMP);
  const xmpPacket = xmpEntry
    ? new TextDecoder().decode(buf.subarray(xmpEntry.dataOffset, xmpEntry.dataOffset + xmpEntry.byteLength))
    : null;
  const packet = xmpPacket ?? '';
  const item = firstProfileItem(packet);

  return {
    header,
    ifd,
    identity: {
      make: readAscii(buf, ifd.entries.get(TAG.Make)),
      model: readAscii(buf, ifd.entries.get(TAG.Model)),
      uniqueCameraModel: readAscii(buf, ifd.entries.get(TAG.UniqueCameraModel)),
    },
    profiles: {
      make: readXmpProperty(item, 'stCamera:Make'),
      model: readXmpProperty(item, 'stCamera:Model'),
      uniqueCameraModel: readXmpProperty(item, 'stCamera:UniqueCameraModel'),
      cameraRawProfile: readXmpProperty(item, 'stCamera:CameraRawProfile'),
    },
    stash: {
      originalMake: readXmpProperty(packet, 'fujify:OriginalMake'),
      originalModel: readXmpProperty(packet, 'fujify:OriginalModel'),
      originalUniqueCameraModel: readXmpProperty(packet, 'fujify:OriginalUniqueCameraModel'),
      targetModel: readXmpProperty(packet, 'fujify:TargetModel'),
      version: readXmpProperty(packet, 'fujify:Version'),
    },
    xmpPacket,
  };
}

/** Contract §3.2: a file that already carries a stash keeps it, rather than having the faked identity stashed over it. */
export function hasStash(info: DngInfo): boolean {
  return info.stash.originalMake !== '';
}
