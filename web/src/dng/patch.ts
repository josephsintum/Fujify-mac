// Turns "tag this DNG as a Fujifilm X-T5" into a list of byte edits.
//
// The rule that makes this safe: no existing byte is ever moved. A value either
// fits where the old one lived, or it is appended at EOF and its IFD entry is
// repointed. SubIFDs, MakerNotes, previews and the embedded original all hold
// absolute offsets, and all of them stay valid because nothing shifts.
//
// The single exception is a tag that does not exist yet and so needs a new IFD0
// entry. IFD0 then has to grow, so a copy of it goes at EOF and the header's
// IFD0 pointer is repointed. Existing entries are copied verbatim, offsets and all.

import { type DngInfo, hasStash, readDng } from './identity';
import { TAG, view } from './tiff';
import { EMPTY_PACKET, type TargetCamera, fitPacket, freshPacket, rewriteXmp } from './xmp';

export interface PatchEdit {
  offset: number;
  bytes: Uint8Array;
}

export interface PatchPlan {
  /** Overwrites, all within the original file's length. */
  edits: PatchEdit[];
  /** Bytes to write at exactly the original EOF, or null. Alignment padding is included. */
  append: Uint8Array | null;
  outputLength: number;
  relocatedIfd: boolean;
}

/** What a tag's value should end up being, and where. */
interface Placement {
  tag: number;
  type: number;
  /** Value length in bytes, which for our ASCII and BYTE tags is also the TIFF count. */
  count: number;
  /** Absolute file offset of the value bytes once the plan is applied, or null when inline. */
  dataOffset: number | null;
  /**
   * The 4-byte value field, for a value of 4 bytes or fewer. TIFF stores such a value
   * INSIDE the 12-byte entry, and every reader — readIfd0 included — decides that from
   * the count alone. Writing an offset there instead would be read back as the value.
   */
  inline: Uint8Array | null;
}

/** The four bytes that go in the entry's value field: the inline value, or an offset. */
function valueField(p: Placement, littleEndian: boolean): Uint8Array {
  return p.inline ?? u32(p.dataOffset!, littleEndian);
}

class Appender {
  private readonly chunks: { at: number; bytes: Uint8Array }[] = [];
  private cursor: number;

  constructor(private readonly start: number) {
    // TIFF values are word-aligned by convention; keep that up for anything we add.
    this.cursor = start + (start & 1);
  }

  push(bytes: Uint8Array): number {
    const at = this.cursor;
    this.chunks.push({ at, bytes });
    this.cursor += bytes.byteLength + (bytes.byteLength & 1);
    return at;
  }

  /** One buffer starting at the original EOF, with alignment gaps as zero bytes. */
  build(): Uint8Array | null {
    if (this.chunks.length === 0) return null;
    const out = new Uint8Array(this.cursor - this.start);
    for (const { at, bytes } of this.chunks) out.set(bytes, at - this.start);
    return out;
  }
}

function u32(value: number, littleEndian: boolean): Uint8Array {
  const out = new Uint8Array(4);
  new DataView(out.buffer).setUint32(0, value, littleEndian);
  return out;
}

/** The new UniqueCameraModel value, and where it will live. */
function placeUniqueCameraModel(
  info: DngInfo,
  target: TargetCamera,
  appender: Appender,
  edits: PatchEdit[],
): Placement {
  const bytes = new TextEncoder().encode(`${target.uniqueCameraModel}\0`);
  const existing = info.ifd.entries.get(TAG.UniqueCameraModel);
  const base = { tag: TAG.UniqueCameraModel, type: 2, count: bytes.byteLength };

  if (bytes.byteLength <= 4) {
    // A value this short belongs in the entry itself, whatever the old one did. Going
    // out of line here would set a count of <= 4 beside an offset, and the reader would
    // hand back the first bytes of that offset as the model name.
    const field = new Uint8Array(4);
    field.set(bytes);
    return { ...base, dataOffset: null, inline: field };
  }

  if (existing && !existing.inline && bytes.byteLength <= existing.byteLength) {
    // Fits where it is: overwrite and NUL-pad the rest, then shorten the count.
    const padded = new Uint8Array(existing.byteLength);
    padded.set(bytes);
    edits.push({ offset: existing.dataOffset, bytes: padded });
    return { ...base, dataOffset: existing.dataOffset, inline: null };
  }

  return { ...base, dataOffset: appender.push(bytes), inline: null };
}

/** The new XMP packet, and where it will live. */
function placeXmp(
  info: DngInfo,
  target: TargetCamera,
  appender: Appender,
  edits: PatchEdit[],
): Placement {
  const { body, trailer } = rewriteXmp(
    info.xmpPacket ?? EMPTY_PACKET,
    target,
    info.identity,
    hasStash(info),
  );
  const existing = info.ifd.entries.get(TAG.XMP);

  if (existing && !existing.inline) {
    const fitted = fitPacket(body, trailer, existing.byteLength);
    if (fitted) {
      // The whole point: the packet's padding absorbs the change, so the file
      // differs from the original by a few hundred bytes in the middle and nothing else.
      edits.push({ offset: existing.dataOffset, bytes: fitted });
      return {
        tag: TAG.XMP,
        type: existing.type,
        count: existing.byteLength,
        dataOffset: existing.dataOffset,
        inline: null,
      };
    }
  }

  const packet = freshPacket(body, trailer);
  // Keep whatever type the existing entry declared — exiftool writes 1 (BYTE) but
  // 7 (UNDEFINED) is equally legal for XMP, and rewriting it is a change we do not
  // need to make. Only a tag we are adding from nothing gets to pick.
  return {
    tag: TAG.XMP,
    type: existing?.type ?? 1,
    count: packet.byteLength,
    dataOffset: appender.push(packet),
    inline: null,
  };
}

/**
 * Builds a replacement IFD0 at EOF with `placements` merged in, for the case where a
 * tag has to be added. Existing entries are copied byte for byte — their offsets are
 * absolute and the data they point at has not moved.
 *
 * Returns the absolute offset the new IFD0 landed at.
 */
function relocateIfd0(
  buf: Uint8Array,
  info: DngInfo,
  placements: Placement[],
  appender: Appender,
  littleEndian: boolean,
): number {
  const byTag = new Map<number, Uint8Array>();

  for (const entry of info.ifd.entries.values()) {
    byTag.set(entry.tag, buf.slice(entry.entryOffset, entry.entryOffset + 12));
  }

  for (const p of placements) {
    const record = new Uint8Array(12);
    const dv = new DataView(record.buffer);
    dv.setUint16(0, p.tag, littleEndian);
    dv.setUint16(2, p.type, littleEndian);
    dv.setUint32(4, p.count, littleEndian);
    record.set(valueField(p, littleEndian), 8);
    byTag.set(p.tag, record);
  }

  const tags = [...byTag.keys()].sort((a, b) => a - b);
  const ifd = new Uint8Array(2 + tags.length * 12 + 4);
  const dv = new DataView(ifd.buffer);
  dv.setUint16(0, tags.length, littleEndian);
  tags.forEach((tag, i) => ifd.set(byTag.get(tag)!, 2 + i * 12));
  // Preserve the chain: whatever IFD0 pointed at next still lives where it did.
  const next = view(buf).getUint32(info.ifd.nextIfdPointerOffset, littleEndian);
  dv.setUint32(2 + tags.length * 12, next, littleEndian);

  return appender.push(ifd);
}

/**
 * The module's central guarantee, enforced rather than merely intended: every edit
 * lands inside the original file, no two edits overlap, and the output is the original
 * plus the append and nothing else. Any of those failing means a byte that already
 * existed has moved or been clobbered — and the SubIFDs, MakerNotes, previews and
 * embedded original that hold absolute offsets are only valid because none does.
 *
 * Exported for the tests, which feed it hand-built plans; callers want planPatch.
 */
export function validatePlan(buf: Uint8Array, plan: PatchPlan): void {
  const expected = buf.byteLength + (plan.append?.byteLength ?? 0);
  if (plan.outputLength !== expected) {
    throw new Error(
      `plan outputLength ${plan.outputLength} is not the original ${buf.byteLength} plus its append (${expected})`,
    );
  }

  const sorted = [...plan.edits].sort((a, b) => a.offset - b.offset);
  let prevEnd = 0;
  let prevOffset = -1;
  for (const edit of sorted) {
    const end = edit.offset + edit.bytes.byteLength;
    if (edit.offset < 0 || end > buf.byteLength) {
      throw new Error(
        `plan edit at ${edit.offset}..${end} is outside the original file (0..${buf.byteLength})`,
      );
    }
    if (edit.offset < prevEnd) {
      throw new Error(`plan edits overlap: ${prevOffset}..${prevEnd} and ${edit.offset}..${end}`);
    }
    prevEnd = end;
    prevOffset = edit.offset;
  }
}

export function planPatch(buf: Uint8Array, target: TargetCamera): PatchPlan {
  const info = readDng(buf);
  const le = info.header.littleEndian;
  const edits: PatchEdit[] = [];
  const appender = new Appender(buf.byteLength);

  const placements = [
    placeUniqueCameraModel(info, target, appender, edits),
    placeXmp(info, target, appender, edits),
  ];

  const missing = placements.filter((p) => !info.ifd.entries.has(p.tag));

  if (missing.length > 0) {
    // IFD0 must grow. Rebuild it at EOF with every placement written fresh, since the
    // old IFD0 becomes dead bytes and editing it would have no effect.
    const ifdOffset = relocateIfd0(buf, info, placements, appender, le);
    const append = appender.build();
    edits.push({ offset: 4, bytes: u32(ifdOffset, le) });
    const plan: PatchPlan = {
      edits,
      append,
      outputLength: buf.byteLength + append!.byteLength,
      relocatedIfd: true,
    };
    validatePlan(buf, plan);
    return plan;
  }

  // Every tag already has an entry: update count and value offset in each one.
  for (const p of placements) {
    const entry = info.ifd.entries.get(p.tag)!;
    const record = new Uint8Array(8);
    new DataView(record.buffer).setUint32(0, p.count, le);
    record.set(valueField(p, le), 4);
    edits.push({ offset: entry.entryOffset + 4, bytes: record });
  }

  const append = appender.build();
  const plan: PatchPlan = {
    edits,
    append,
    outputLength: buf.byteLength + (append?.byteLength ?? 0),
    relocatedIfd: false,
  };
  validatePlan(buf, plan);
  return plan;
}

/** Applies a plan to a copy of the buffer. Used by tests and the in-memory output sinks. */
export function applyPlan(buf: Uint8Array, plan: PatchPlan): Uint8Array {
  const out = new Uint8Array(plan.outputLength);
  out.set(buf, 0);
  if (plan.append) out.set(plan.append, buf.byteLength);
  for (const { offset, bytes } of plan.edits) out.set(bytes, offset);
  return out;
}

/**
 * Contract §9: skip only when the file already carries *this* target's identity.
 * A file tagged X-T5 is not skipped when the target is X100VI — re-tagging a batch
 * to pick up Reala Ace is exactly why the target picker exists.
 */
export function isAlreadyTagged(buf: Uint8Array, target: TargetCamera): boolean {
  const { profiles } = readDng(buf);
  return (
    profiles.make === target.make &&
    profiles.model === target.model &&
    profiles.uniqueCameraModel === target.uniqueCameraModel
  );
}
