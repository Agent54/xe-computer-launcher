const decoder = new TextDecoder('ascii', { fatal: true });

function u16(bytes, offset) {
  return (bytes[offset] << 8) | bytes[offset + 1];
}

function u24(bytes, offset) {
  return (bytes[offset] << 16) | (bytes[offset + 1] << 8) | bytes[offset + 2];
}

function serverName(handshake) {
  if (handshake.length < 38 || handshake[0] !== 1) return null;
  const size = u24(handshake, 1);
  if (size + 4 > handshake.length) return null;
  let offset = 4 + 2 + 32;
  const sessionLength = handshake[offset++];
  offset += sessionLength;
  if (offset + 2 > handshake.length) return null;
  offset += 2 + u16(handshake, offset);
  if (offset + 1 > handshake.length) return null;
  offset += 1 + handshake[offset];
  if (offset + 2 > handshake.length) return null;
  const extensionsEnd = offset + 2 + u16(handshake, offset);
  offset += 2;
  if (extensionsEnd > handshake.length) return null;
  while (offset + 4 <= extensionsEnd) {
    const type = u16(handshake, offset);
    const end = offset + 4 + u16(handshake, offset + 2);
    if (end > extensionsEnd) return null;
    if (type === 0) {
      const list = offset + 4;
      if (list + 2 > end || list + 2 + u16(handshake, list) !== end) return null;
      let name = list + 2;
      while (name + 3 <= end) {
        const nameEnd = name + 3 + u16(handshake, name + 1);
        if (nameEnd > end) return null;
        if (handshake[name] === 0) {
          try { return decoder.decode(handshake.subarray(name + 3, nameEnd)).toLowerCase(); }
          catch { return null; }
        }
        name = nameEnd;
      }
      return null;
    }
    offset = end;
  }
  return null;
}

// undefined means more bytes are needed; null means this is not a TLS ClientHello.
export function clientHelloServerName(bytes) {
  let offset = 0;
  let handshake = new Uint8Array(0);
  while (offset < bytes.length) {
    if (bytes.length - offset < 5) return undefined;
    if (bytes[offset] !== 22 || bytes[offset + 1] !== 3) return null;
    const end = offset + 5 + u16(bytes, offset + 3);
    if (end > bytes.length) return undefined;
    const next = new Uint8Array(handshake.length + end - offset - 5);
    next.set(handshake);
    next.set(bytes.subarray(offset + 5, end), handshake.length);
    handshake = next;
    if (handshake.length >= 4) {
      if (handshake[0] !== 1) return null;
      if (handshake.length >= 4 + u24(handshake, 1)) return serverName(handshake);
    }
    offset = end;
  }
  return undefined;
}
