// Preserve the TLS byte stream while workerd carries it across the VM socket.
export async function bridgeSocketAndWebSocket(socket, webSocket, initialBytes) {
  webSocket.binaryType = 'arraybuffer';
  webSocket.accept();
  const writer = socket.writable.getWriter();
  let writes = Promise.resolve();
  webSocket.addEventListener('message', event => {
    const bytes = event.data instanceof ArrayBuffer ? new Uint8Array(event.data) : event.data;
    if (!(bytes instanceof Uint8Array)) { webSocket.close(1003); return; }
    writes = writes.then(() => writer.write(bytes)).catch(() => { try { webSocket.close(); } catch {} });
  });
  const closed = new Promise(resolve => webSocket.addEventListener('close', resolve, { once: true }));
  const pump = (async () => {
    const reader = socket.readable.getReader();
    try {
      if (initialBytes) webSocket.send(initialBytes);
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        webSocket.send(value);
      }
    } catch { /* Closing either side ends the tunnel. */ }
    finally {
      reader.releaseLock();
      try { webSocket.close(); } catch {}
    }
  })();
  await Promise.race([pump, closed]);
  try { await socket.close(); } catch {}
  await Promise.allSettled([pump, writes]);
}

// UI and HTTP-app hostnames are terminated by a separate local HTTPS Workerd
// socket. HTTPS-app SNI names continue unmodified to their containers.
export async function bridgeSocketAndSocket(client, upstream, initialBytes) {
  const writer = upstream.writable.getWriter();
  try { await writer.write(initialBytes); } finally { writer.releaseLock(); }
  const inbound = client.readable.pipeTo(upstream.writable).catch(error => { console.warn('TLS inbound bridge:', error); });
  const outbound = upstream.readable.pipeTo(client.writable).catch(error => { console.warn('TLS outbound bridge:', error); });
  await Promise.race([inbound, outbound]);
  await Promise.allSettled([client.close(), upstream.close()]);
  await Promise.allSettled([inbound, outbound]);
}
