import { describe, expect, it } from 'vitest';
import { EMPTY_PACKET, NS, fitPacket, freshPacket, rewriteXmp } from '../../src/dng/xmp';
import { readXmpProperty } from '../../src/dng/identity';
import { xmpPacket } from '../helpers/synth';

const XT5 = { make: 'FUJIFILM', model: 'X-T5', uniqueCameraModel: 'Fujifilm X-T5' };
const X100VI = { make: 'FUJIFILM', model: 'X100VI', uniqueCameraModel: 'Fujifilm X100VI' };
const SONY = { make: 'SONY', model: 'ILCE-7S', uniqueCameraModel: 'Sony ILCE-7S' };

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
