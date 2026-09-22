import { describe, expect, it } from 'vitest';
import { EMPTY_PACKET, NS, encodeEntities, fitPacket, freshPacket, rewriteXmp } from '../../src/dng/xmp';
import { decodeEntities, readXmpProperty } from '../../src/dng/identity';
import { xmpPacket } from '../helpers/synth';

const XT5 = { make: 'FUJIFILM', model: 'X-T5', uniqueCameraModel: 'Fujifilm X-T5' };
const X100VI = { make: 'FUJIFILM', model: 'X100VI', uniqueCameraModel: 'Fujifilm X100VI' };
const SONY = { make: 'SONY', model: 'ILCE-7S', uniqueCameraModel: 'Sony ILCE-7S' };

/**
 * Asserts an XML fragment is tag-balanced: every element name opened is closed the
 * same number of times. Self-closing tags (`<.../>`) and processing instructions
 * (`<?...?>`) neither open nor close anything, so they are excluded — a PI never
 * matches this tag pattern at all, since `<?` is not `<` followed by a name.
 */
function assertBalanced(xml: string): void {
  const tagRe = /<\/?([A-Za-z_][\w.-]*:[\w.-]+|[A-Za-z_][\w.-]*)\b[^>]*?(\/?)>/g;
  const counts = new Map<string, number>();
  let m: RegExpExecArray | null;
  while ((m = tagRe.exec(xml))) {
    const name = m[1]!;
    const selfClosing = m[2] === '/';
    if (selfClosing) continue;
    const isClosing = m[0].startsWith('</');
    counts.set(name, (counts.get(name) ?? 0) + (isClosing ? -1 : 1));
  }
  for (const [name, count] of counts) {
    expect(count, `tag <${name}> is unbalanced (net ${count})`).toBe(0);
  }
}

describe('rewriteXmp', () => {
  it('writes the four profile values and the five stash values', () => {
    const { body } = rewriteXmp(xmpPacket(4096), XT5, SONY, false);
    expect(readXmpProperty(body, 'stCamera:Make')).toBe('FUJIFILM');
    expect(readXmpProperty(body, 'stCamera:Model')).toBe('X-T5');
    expect(readXmpProperty(body, 'stCamera:UniqueCameraModel')).toBe('Fujifilm X-T5');
    expect(readXmpProperty(body, 'stCamera:CameraRawProfile')).toBe('True');
    expect(readXmpProperty(body, 'fujify:OriginalMake')).toBe('SONY');
    expect(readXmpProperty(body, 'fujify:OriginalModel')).toBe('ILCE-7S');
    expect(readXmpProperty(body, 'fujify:OriginalUniqueCameraModel')).toBe('Sony ILCE-7S');
    expect(readXmpProperty(body, 'fujify:TargetModel')).toBe('X-T5');
    expect(readXmpProperty(body, 'fujify:Version')).toBe('1');
  });

  it('declares the three namespaces with the exact contract URIs', () => {
    const { body } = rewriteXmp(xmpPacket(4096), XT5, SONY, false);
    expect(body).toContain(`xmlns:photoshop="${NS.photoshop}"`);
    expect(body).toContain(`xmlns:stCamera="${NS.stCamera}"`);
    expect(body).toContain(`xmlns:fujify="${NS.fujify}"`);
    expect(NS.stCamera).toBe('http://ns.adobe.com/photoshop/1.0/camera-profile');
    expect(NS.fujify).toBe('https://josephsintum.dev/ns/fujify/1.0/');
  });

  it('does not declare a namespace the packet already declares', () => {
    const declared = xmpPacket(64).replace(
      'xmlns:tiff=',
      `xmlns:photoshop="${NS.photoshop}"\n    xmlns:tiff=`,
    );
    const { body } = rewriteXmp(declared, XT5, SONY, false);
    expect(body.match(/xmlns:photoshop=/g)).toHaveLength(1);
  });

  it('declares a namespace on the element being patched even when only a sibling rdf:Description declares it', () => {
    // Two siblings; only the SECOND declares xmlns:photoshop. rewriteXmp always
    // patches the FIRST rdf:Description, so a document-wide check would see the
    // sibling's declaration, skip declaring it on the first element, and emit
    // photoshop:CameraProfiles there with the prefix unbound — malformed XML.
    const twoSiblings =
      `<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>\n` +
      `<x:xmpmeta xmlns:x="adobe:ns:meta/">\n` +
      ` <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n` +
      `  <rdf:Description rdf:about="">\n` +
      `  </rdf:Description>\n` +
      `  <rdf:Description rdf:about="" xmlns:photoshop="${NS.photoshop}">\n` +
      `  </rdf:Description>\n` +
      ` </rdf:RDF>\n` +
      `</x:xmpmeta>\n` +
      `<?xpacket end='w'?>`;
    const { body } = rewriteXmp(twoSiblings, XT5, SONY, false);

    // Assert on the FIRST element's own open tag, not the whole body — counting
    // occurrences in the whole body would pass against the old, buggy code too.
    const firstDescStart = body.indexOf('<rdf:Description');
    const firstDescOpenEnd = body.indexOf('>', firstDescStart);
    const firstOpenTag = body.slice(firstDescStart, firstDescOpenEnd + 1);
    expect(firstOpenTag).toContain(`xmlns:photoshop="${NS.photoshop}"`);

    // photoshop:CameraProfiles is inserted into the first Description; sanity check
    // it actually landed inside the element we just asserted has the binding.
    const firstDescClose = body.indexOf('</rdf:Description>');
    expect(body.slice(firstDescOpenEnd, firstDescClose)).toContain('<photoshop:CameraProfiles>');
  });

  it('keeps the trailer, which declares the packet writable in place', () => {
    const { trailer } = rewriteXmp(xmpPacket(4096), XT5, SONY, false);
    expect(trailer).toBe("<?xpacket end='w'?>");
  });

  it('replaces an existing CameraProfiles block rather than adding a second', () => {
    const once = rewriteXmp(xmpPacket(4096), XT5, SONY, false);
    const twice = rewriteXmp(once.body, X100VI, SONY, true);
    expect(twice.body.match(/<photoshop:CameraProfiles>/g)).toHaveLength(1);
    expect(readXmpProperty(twice.body, 'stCamera:Model')).toBe('X100VI');
    expect(readXmpProperty(twice.body, 'stCamera:UniqueCameraModel')).toBe('Fujifilm X100VI');
  });

  it('keeps the original stash on a second pass and updates only TargetModel', () => {
    const once = rewriteXmp(xmpPacket(4096), XT5, SONY, false);
    // Second pass reads the already-faked identity, and must not stash it.
    const twice = rewriteXmp(once.body, X100VI, { make: 'FUJIFILM', model: 'X-T5', uniqueCameraModel: 'Fujifilm X-T5' }, true);
    expect(readXmpProperty(twice.body, 'fujify:OriginalMake')).toBe('SONY');
    expect(readXmpProperty(twice.body, 'fujify:OriginalUniqueCameraModel')).toBe('Sony ILCE-7S');
    expect(readXmpProperty(twice.body, 'fujify:TargetModel')).toBe('X100VI');
    expect(twice.body.match(/<fujify:TargetModel>/g)).toHaveLength(1);
    expect(twice.body.match(/<fujify:OriginalMake>/g)).toHaveLength(1);
  });

  it('escapes XML metacharacters in a user-added camera name', () => {
    const odd = { make: 'FUJIFILM', model: 'X&<T>5', uniqueCameraModel: 'Fujifilm X&<T>5' };
    const { body } = rewriteXmp(xmpPacket(4096), odd, SONY, false);
    expect(body).toContain('<stCamera:Model>X&amp;&lt;T&gt;5</stCamera:Model>');
    expect(readXmpProperty(body, 'stCamera:Model')).toBe('X&<T>5');
  });

  it('handles a self-closing rdf:Description', () => {
    const selfClosing =
      `<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>\n` +
      `<x:xmpmeta xmlns:x="adobe:ns:meta/">\n <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n` +
      `  <rdf:Description rdf:about=""/>\n </rdf:RDF>\n</x:xmpmeta>\n<?xpacket end='w'?>`;
    const { body } = rewriteXmp(selfClosing, XT5, SONY, false);
    expect(readXmpProperty(body, 'stCamera:Model')).toBe('X-T5');
    expect(body).toContain('</rdf:Description>');
  });

  it('builds a packet from EMPTY_PACKET when the file had none', () => {
    const { body, trailer } = rewriteXmp(EMPTY_PACKET, XT5, SONY, false);
    expect(readXmpProperty(body, 'stCamera:UniqueCameraModel')).toBe('Fujifilm X-T5');
    expect(trailer).toBe("<?xpacket end='w'?>");
  });

  it('drops control bytes that XML 1.0 cannot represent at all', () => {
    // readAscii passes any non-NUL byte through, so a stray 0x0B in the source Make
    // reaches the stash. XML has no escape for it, so leaving it in makes a strict
    // parser reject the ENTIRE packet — taking the file's own crs develop settings,
    // xmpMM history, ratings and keywords with it, not just our block.
    const dirty = { make: 'SO\x0bNY', model: 'ILCE\x01-7S', uniqueCameraModel: 'Sony\x1f ILCE-7S' };
    const { body } = rewriteXmp(xmpPacket(4096), XT5, dirty, false);
    expect(body).not.toMatch(/[\x00-\x08\x0B\x0C\x0E-\x1F]/);
    expect(readXmpProperty(body, 'fujify:OriginalMake')).toBe('SONY');
    expect(readXmpProperty(body, 'fujify:OriginalModel')).toBe('ILCE-7S');
    assertBalanced(body);
  });

  it('finds the end of the open tag when an attribute value contains a >', () => {
    // '>' is legal unescaped inside an attribute value. Scanning for the first '>'
    // truncates the open tag, so the xmlns check misses a declaration the tag already
    // carries and re-declares it — a duplicate attribute, which xmllint rejects.
    const withGt =
      `<?xpacket begin="\ufeff" id="W5M0MpCehiHzreSzNTczkc9d"?>\n` +
      `<x:xmpmeta xmlns:x="adobe:ns:meta/">\n` +
      ` <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n` +
      `  <rdf:Description rdf:about="" photoshop:Headline="a > b" xmlns:photoshop="${NS.photoshop}">\n` +
      `  </rdf:Description>\n </rdf:RDF>\n</x:xmpmeta>\n<?xpacket end='w'?>`;
    const { body } = rewriteXmp(withGt, XT5, SONY, false);

    for (const prefix of Object.keys(NS)) {
      expect(body.match(new RegExp(`xmlns:${prefix}=`, 'g')), prefix).toHaveLength(1);
    }
    expect(body).toContain('photoshop:Headline="a > b"');
    expect(readXmpProperty(body, 'stCamera:Model')).toBe('X-T5');
    assertBalanced(body);
  });

  it('strips an attribute-form fujify:TargetModel, which would otherwise survive', () => {
    // readXmpProperty prefers the element form, so the reader here would look right —
    // but exiftool lists BOTH values with the stale attribute first, and that is what
    // verify-dng.sh and the macOS app read.
    const attrForm =
      `<?xpacket begin="\ufeff" id="W5M0MpCehiHzreSzNTczkc9d"?>\n` +
      `<x:xmpmeta xmlns:x="adobe:ns:meta/">\n` +
      ` <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n` +
      `  <rdf:Description rdf:about="" xmlns:fujify="${NS.fujify}" fujify:TargetModel="STALE">\n` +
      `  </rdf:Description>\n </rdf:RDF>\n</x:xmpmeta>\n<?xpacket end='w'?>`;
    const { body } = rewriteXmp(attrForm, X100VI, SONY, false);

    expect(body).not.toContain('STALE');
    expect(body.match(/fujify:TargetModel/g)).toHaveLength(2); // the element's open and close tags
    expect(readXmpProperty(body, 'fujify:TargetModel')).toBe('X100VI');
    assertBalanced(body);
  });

  it('is idempotent with keepStash false, rather than accumulating stashes', () => {
    // patch.ts always passes hasStash(info), so this state is unreachable through it.
    // Closing it here is cheaper than the test that would otherwise have to guard it.
    const once = rewriteXmp(xmpPacket(4096), XT5, SONY, false);
    const twice = rewriteXmp(once.body, X100VI, SONY, false);
    for (const name of ['OriginalMake', 'OriginalModel', 'OriginalUniqueCameraModel', 'Version']) {
      expect(twice.body.match(new RegExp(`<fujify:${name}>`, 'g')), name).toHaveLength(1);
    }
    assertBalanced(twice.body);
  });

  it('re-emits fujify:Version on a re-tag, as mac/Engine/ExifTool.swift does', () => {
    const once = rewriteXmp(xmpPacket(4096), XT5, SONY, false);
    const twice = rewriteXmp(once.body, X100VI, XT5, true);
    expect(twice.body.match(/<fujify:Version>/g)).toHaveLength(1);
    expect(readXmpProperty(twice.body, 'fujify:Version')).toBe('1');
  });

  it('rejects a packet with no x:xmpmeta', () => {
    expect(() => rewriteXmp('<not-xmp/>', XT5, SONY, false)).toThrow(/xmpmeta/);
  });
});

describe('fitPacket', () => {
  it('returns a buffer of exactly the requested length', () => {
    const { body, trailer } = rewriteXmp(xmpPacket(4096), XT5, SONY, false);
    const out = fitPacket(body, trailer, 4096 + 1000)!;
    expect(out).not.toBeNull();
    expect(out.byteLength).toBe(4096 + 1000);
  });

  it('ends with the trailer so readers see a terminated packet', () => {
    const { body, trailer } = rewriteXmp(xmpPacket(4096), XT5, SONY, false);
    const out = fitPacket(body, trailer, 6000)!;
    const text = new TextDecoder().decode(out);
    expect(text.endsWith(trailer)).toBe(true);
    expect(readXmpProperty(text, 'stCamera:Model')).toBe('X-T5');
  });

  it('pads with spaces and a newline every 101st byte, as Adobe does', () => {
    const out = fitPacket('<a/>', '<?xpacket end=\'w\'?>', 400)!;
    const text = new TextDecoder().decode(out);
    const pad = text.slice('<a/>'.length, 400 - "<?xpacket end='w'?>".length);
    expect(pad).toMatch(/^[ \n]+$/);
    expect(pad.split('\n').length).toBeGreaterThan(1);
  });

  it('returns null when the content cannot fit even with no padding', () => {
    const { body, trailer } = rewriteXmp(xmpPacket(4096), XT5, SONY, false);
    expect(fitPacket(body, trailer, 10)).toBeNull();
  });

  it('fits exactly when the length is body + trailer with no room to spare', () => {
    const body = '<a/>';
    const trailer = "<?xpacket end='w'?>";
    const exact = body.length + trailer.length;
    expect(fitPacket(body, trailer, exact)).not.toBeNull();
    expect(fitPacket(body, trailer, exact - 1)).toBeNull();
  });
});

describe('freshPacket', () => {
  it('adds its own padding so a later pass can edit in place', () => {
    const { body, trailer } = rewriteXmp(xmpPacket(0), XT5, SONY, false);
    const out = freshPacket(body, trailer);
    const text = new TextDecoder().decode(out);
    expect(out.byteLength).toBeGreaterThan(body.length + trailer.length + 2000);
    expect(text.endsWith(trailer)).toBe(true);
  });
});

describe('structural well-formedness', () => {
  it('produces a tag-balanced body, from a self-closing rdf:Description and across a two-pass rewrite', () => {
    const selfClosing =
      `<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>\n` +
      `<x:xmpmeta xmlns:x="adobe:ns:meta/">\n <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n` +
      `  <rdf:Description rdf:about=""/>\n </rdf:RDF>\n</x:xmpmeta>\n<?xpacket end='w'?>`;
    assertBalanced(rewriteXmp(selfClosing, XT5, SONY, false).body);

    const once = rewriteXmp(xmpPacket(4096), XT5, SONY, false);
    assertBalanced(once.body);
    const twice = rewriteXmp(once.body, X100VI, SONY, true);
    assertBalanced(twice.body);
  });
});

describe('entity encoding', () => {
  // encodeEntities replaces '&' FIRST and decodeEntities replaces '&amp;' LAST. That
  // ordering is the whole reason the pair round-trips; swap either and '&lt;' in a
  // camera name comes back as '<'. Nothing asserted it until now.
  const cases = [
    '&', '<', '>', '"', "'",
    '&amp;', '&lt;', '&gt;', '&quot;', '&apos;', '&#39;',
    '&amp', ';', '#39', '&amp;lt;', '&&&', '<&>"',
    'Fujifilm X-T5',
  ];

  for (const s of cases) {
    it(`round-trips ${JSON.stringify(s)}`, () => {
      expect(decodeEntities(encodeEntities(s))).toBe(s);
    });
  }
});
