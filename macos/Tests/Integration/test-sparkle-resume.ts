const [client, bundleID, output, cache] = Deno.args;
const server = Deno.listen({ hostname: "127.0.0.1", port: 0 });
const url = `http://127.0.0.1:${server.addr.port}/release.dmg`;
const chunk = 256 * 1024;
const archive = Uint8Array.from({ length: 3 * chunk }, (_, i) => i % 251);
const replacement = archive.map((byte) => 255 - byte);

async function writeAll(conn: Deno.Conn, bytes: Uint8Array) {
  while (bytes.length) bytes = bytes.subarray(await conn.write(bytes));
}

async function readHeaders(conn: Deno.Conn, path: string, method = "GET") {
  const buffer = new Uint8Array(4096);
  let headers = "";
  while (!headers.includes("\r\n\r\n")) {
    const count = await conn.read(buffer);
    if (count === null) throw new Error("Client closed before sending headers");
    headers += new TextDecoder().decode(buffer.subarray(0, count));
  }
  if (!headers.startsWith(`${method} ${path} HTTP/1.1\r\n`)) {
    throw new Error(`Expected ${path}, got ${headers.split("\r\n")[0]}`);
  }
  return headers;
}

type Reply = "interrupt" | "wrong-range" | "complete" | "replace" | "checkpoint-at-end" | "unconfirmed" | "metadata-missing" | "cached" | "changed";

async function serve(offset: number, reply: Reply, progress: ReadableStream<Uint8Array>) {
  // A cached signed CDN URL is unusable on the next attempt.
  const cdnPath = `/cdn/${crypto.randomUUID()}/release.dmg`;
  using redirect = await server.accept();
  await readHeaders(redirect, "/release.dmg");
  const location = `http://localhost:${server.addr.port}${cdnPath}`;
  const redirectHeaders = `HTTP/1.1 302 Found\r\nLocation: ${location}\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`;
  await writeAll(redirect, new TextEncoder().encode(redirectHeaders));

  using conn = await server.accept();
  const headers = await readHeaders(conn, cdnPath);
  const range = /^range:\s*(.*)\r$/im.exec(headers)?.[1];
  if (range !== (offset ? `bytes=${offset}-` : undefined)) throw new Error(`Unexpected Range: ${range}`);
  if (offset && !/^if-range:\s*"fixture"\r$/im.test(headers)) throw new Error("Missing If-Range validator");

  if (reply === "cached" || reply === "unconfirmed" || reply === "metadata-missing" || reply === "changed") {
    const recover = reply === "unconfirmed" || reply === "metadata-missing";
    const tag = recover ? "" : `ETag: "${reply === "changed" ? "new" : "fixture"}"\r\n`;
    const response = `HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */${archive.length}\r\n${tag}Content-Type: text/plain\r\nConnection: close\r\nContent-Length: 5\r\n\r\nerror`;
    await writeAll(conn, new TextEncoder().encode(response));
    if (recover) {
      // Retry must validate metadata from the release URL, not repeat the
      // rejected range or reuse the old signed CDN URL.
      using metadata = await server.accept();
      const headers = await readHeaders(metadata, "/release.dmg", "HEAD");
      if (/^range:/im.test(headers)) throw new Error("Metadata request sent a range");
      const partial = `${cache}/${Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(url))), b => b.toString(16).padStart(2, "0")).join("")}`;
      const saved = await Deno.readFile(partial);
      if (saved.length !== archive.length) throw new Error("416 discarded saved bytes before validation");
      const validator = reply === "unconfirmed" ? 'ETag: "fixture"\r\n' : "";
      await writeAll(metadata, new TextEncoder().encode(`HTTP/1.1 200 OK\r\n${validator}Content-Length: ${archive.length}\r\nConnection: close\r\n\r\n`));
      if (reply === "metadata-missing") {
        using full = await server.accept();
        const headers = await readHeaders(full, "/release.dmg");
        if (/^range:/im.test(headers)) throw new Error("Unverifiable metadata repeated the failed range");
        if ((await Deno.readFile(partial)).length !== archive.length) throw new Error("Metadata probe discarded saved bytes");
        await writeAll(full, new TextEncoder().encode(`HTTP/1.1 200 OK\r\nContent-Length: ${archive.length}\r\nConnection: close\r\n\r\n`));
        await writeAll(full, archive);
      }
    }
    return;
  }
  const start = reply === "replace" ? 0 : offset;
  const body = reply === "replace" ? replacement : archive;
  const response = [
    start ? "HTTP/1.1 206 Partial Content" : "HTTP/1.1 200 OK",
    "Accept-Ranges: bytes",
    reply === "replace" ? 'ETag: "replacement"' : 'ETag: "fixture"',
    "Content-Type: application/octet-stream",
    "Connection: close",
    `Content-Length: ${body.length - start + (reply === "checkpoint-at-end" ? 1 : 0)}`,
  ];
  if (start) {
    const first = reply === "wrong-range" ? start - 1 : start;
    response.push(`Content-Range: bytes ${first}-${body.length - 1}/${body.length}`);
  }
  await writeAll(conn, new TextEncoder().encode(response.join("\r\n") + "\r\n\r\n"));
  if (reply === "wrong-range") return;
  await writeAll(conn, body.subarray(start, reply === "interrupt" ? start + chunk : body.length));
  if (reply === "interrupt" || reply === "checkpoint-at-end") {
    // Drop the connection once the client has actually received the prefix.
    if ((await progress.getReader().read()).done) throw new Error("Client exited before checkpoint");
  }
}

async function attempt(offset: number, reply: Reply) {
  const checkpoint = reply === "checkpoint-at-end" ? archive.length : reply === "interrupt" ? offset + chunk : 0;
  const destination = ["cached", "unconfirmed", "metadata-missing"].includes(reply) ? `${output}.${reply}` : reply === "replace" ? output + ".replacement" : output;
  const child = new Deno.Command(client, {
    args: [url, bundleID, destination, String(checkpoint)],
    stdout: "piped",
  }).spawn();
  const success = ["complete", "replace", "cached", "unconfirmed", "metadata-missing"].includes(reply);
  await Promise.all([
    serve(offset, reply, child.stdout),
    child.status.then(({ code }) => {
      if (code !== (success ? 0 : 2)) throw new Error(`Client exited with ${code} during ${reply}`);
    }),
  ]);
  if (success) {
    const result = await Deno.readFile(destination);
    const expected = reply === "replace" ? replacement : archive;
    if (result.length !== expected.length || !result.every((byte, i) => byte === expected[i])) {
      throw new Error("Delivered archive differs from the original");
    }
  }
}

async function checkResumeRetryLimit() {
  const child = new Deno.Command(client, {
    args: [url.replace("/release.dmg", "/retry-limit.dmg"), bundleID, output, "0"],
    stdout: "piped",
  }).spawn();
  const reader = child.stdout.pipeThrough(new TextDecoderStream()).getReader();
  const exercise = async () => {
    for (let attempt = 0; attempt < 4; attempt++) {
      using conn = await server.accept();
      const headers = await readHeaders(conn, "/retry-limit.dmg");
      const offset = attempt * chunk;
      const range = /^range:\s*(.*)\r$/im.exec(headers)?.[1];
      if (range !== (offset ? `bytes=${offset}-` : undefined)) throw new Error(`Unexpected retry Range: ${range}`);
      const status = offset ? `206 Partial Content\r\nContent-Range: bytes ${offset}-${5 * chunk - 1}/${5 * chunk}` : "200 OK";
      await writeAll(conn, new TextEncoder().encode(`HTTP/1.1 ${status}\r\nContent-Type: application/octet-stream\r\nETag: "limit"\r\nContent-Length: ${5 * chunk - offset}\r\nConnection: close\r\n\r\n`));
      await writeAll(conn, archive.subarray(0, chunk));
      let progress = "";
      while (!progress.split("\n").includes(String(offset + chunk))) {
        const next = await reader.read();
        if (next.done) throw new Error("Downloader exited before receiving the retry prefix");
        progress += next.value;
      }
    }
  };
  await Promise.all([exercise(), child.status.then(({ code }) => {
    if (code !== 2) throw new Error(`Expected failure after three resume retries, got ${code}`);
  })]);
}

async function checkRecoveryDoesNotConsumeRetries() {
  const child = new Deno.Command(client, { args: [url, bundleID, output, "0"], stdout: "piped" }).spawn();
  const reader = child.stdout.pipeThrough(new TextDecoderStream()).getReader();
  let failures = 0;
  const exercise = async () => {
    {
      using range = await server.accept();
      const request = await readHeaders(range, "/release.dmg");
      if (!request.includes(`bytes=${archive.length}-`)) throw new Error("Missing cached range");
      await writeAll(range, new TextEncoder().encode(`HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */${archive.length}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`));
    }
    {
      using head = await server.accept();
      await readHeaders(head, "/release.dmg", "HEAD");
      await writeAll(head, new TextEncoder().encode(`HTTP/1.1 200 OK\r\nContent-Length: ${5 * chunk}\r\nConnection: close\r\n\r\n`));
    }
    for (let attempt = 0; attempt < 4; attempt++) {
      using conn = await server.accept();
      const request = await readHeaders(conn, "/release.dmg");
      const offset = attempt * chunk;
      const range = /^range:\s*(.*)\r$/im.exec(request)?.[1];
      if (range !== (offset ? `bytes=${offset}-` : undefined)) throw new Error(`Unexpected recovery range ${range}`);
      const status = offset ? `206 Partial Content\r\nContent-Range: bytes ${offset}-${5 * chunk - 1}/${5 * chunk}` : "200 OK";
      await writeAll(conn, new TextEncoder().encode(`HTTP/1.1 ${status}\r\nETag: "fixture"\r\nContent-Length: ${5 * chunk - offset}\r\nConnection: close\r\n\r\n`));
      await writeAll(conn, archive.subarray(0, chunk));
      let progress = "";
      while (!progress.split("\n").includes(String(offset + chunk))) {
        const next = await reader.read();
        if (next.done) throw new Error("Downloader stopped before checkpoint");
        progress += next.value;
      }
      failures++;
    }
  };
  await Promise.all([exercise(), child.status.then(({ code }) => {
    if (code !== 2 || failures !== 4) throw new Error(`Recovery consumed retries: ${failures} failures, exit ${code}`);
  })]);
}

async function checkSparkleDelta() {
  const base = `http://127.0.0.1:${server.addr.port}`;
  const child = new Deno.Command(client, { args: [base + "/feed.xml"], stdout: "piped" }).spawn();
  const reader = child.stdout.pipeThrough(new TextDecoderStream()).getReader();
  const exercise = async () => {
    using feed = await server.accept();
    await readHeaders(feed, "/feed.xml");
    const xml = `<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
      <title>Version 2</title><sparkle:version>2</sparkle:version>
      <enclosure url="${base}/full.dmg" length="1000000" type="application/octet-stream"/>
      <sparkle:deltas><enclosure url="${base}/update.delta" sparkle:deltaFrom="1" length="${archive.length}" type="application/octet-stream"/></sparkle:deltas>
      </item></channel></rss>`;
    await writeAll(feed, new TextEncoder().encode(`HTTP/1.1 200 OK\r\nContent-Type: application/xml\r\nContent-Length: ${xml.length}\r\nConnection: close\r\n\r\n${xml}`));
    for (const offset of [0, chunk, 2 * chunk]) {
      using conn = await server.accept();
      const headers = await readHeaders(conn, "/update.delta");
      const range = /^range:\s*(.*)\r$/im.exec(headers)?.[1];
      if (range !== (offset ? `bytes=${offset}-` : undefined)) throw new Error(`Unexpected delta Range: ${range}`);
      const status = offset ? `206 Partial Content\r\nContent-Range: bytes ${offset}-${archive.length - 1}/${archive.length}` : "200 OK";
      await writeAll(conn, new TextEncoder().encode(`HTTP/1.1 ${status}\r\nETag: "delta"\r\nContent-Length: ${archive.length - offset}\r\nConnection: close\r\n\r\n`));
      await writeAll(conn, archive.subarray(offset, offset + chunk));
      if (offset + chunk < archive.length) {
        let progress = "";
        while (!progress.split("\n").includes(String(offset + chunk))) {
          const next = await reader.read();
          if (next.done) throw new Error("Sparkle exited before receiving the delta prefix");
          progress += next.value;
        }
      }
    }
  };
  await Promise.all([exercise(), child.status.then(({ code }) => {
    if (code !== 0) throw new Error(`Sparkle delta update exited with ${code}`);
  })]);
}

try {
  await checkSparkleDelta();
  await checkResumeRetryLimit();
  await attempt(0, "interrupt");
  // Returning after the old ten-day cleanup threshold must still resume.
  for await (const entry of Deno.readDir(cache)) {
    const old = new Date(Date.now() - 11 * 86400 * 1000);
    await Deno.utime(`${cache}/${entry.name}`, old, old);
  }
  await attempt(chunk, "wrong-range");
  await attempt(chunk, "interrupt");
  await attempt(2 * chunk, "complete");
  await attempt(0, "interrupt");
  await attempt(chunk, "replace");
  await attempt(0, "checkpoint-at-end");
  await attempt(archive.length, "unconfirmed");
  await attempt(0, "checkpoint-at-end");
  await attempt(archive.length, "metadata-missing");
  await attempt(0, "checkpoint-at-end");
  await attempt(archive.length, "cached");
  await attempt(0, "checkpoint-at-end");
  await attempt(archive.length, "changed");
  await attempt(0, "checkpoint-at-end");
  await checkRecoveryDoesNotConsumeRetries();
  console.log("PASS: Sparkle resumed the selected delta and aged partial, capped resume retries at three, and recovered 416 responses with and without metadata validators");
} finally {
  server.close();
}
