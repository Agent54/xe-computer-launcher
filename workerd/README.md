# Host gateway and guest router

The host gateway, its private HTTPS terminator, and the guest router connect
the launcher UI to Compose and running containers:

- **Host:** `gateway.js` protects the management socket, `app-gateway.js` routes
  shared app HTTP/HTTPS, and `management.js` serves the UI and forwards API requests
  to the Compose server on macOS. The separate workers prevent a forged Host
  header on the management socket from entering app routing.
- **Discovery:** `app-discovery.js` resolves running, stopped, and uncreated apps
  through Compose's existing project, config, and service APIs. Project/config
  variants share a 100 ms server cache across hostnames and port selectors;
  app-request startup completion invalidates the affected variant. Docker lookup has the
  same 100 ms limit. Cache expiry is measured from fetch start, so slow requests
  cannot extend the reuse window. Pending requests share a fetch; these caches
  are held in Workerd memory and never stored in the browser.
- **Guest:** `router.js` runs inside SmolVM. It validates the exact container ID
  and published/target port pair selected by the host against Docker, resolves
  the current container address, and forwards the request. The host connects to
  it through a Unix socket exposed by SmolVM.

The launcher starts the Compose UI server but does not open it or provide a
session token. The IWA UI handles access to Compose.

## Port routes

Use Compose's standard [long port syntax](https://docs.docker.com/reference/compose-file/services/#ports)
to name a port:

```yaml
services:
  app:
    image: my-app
    ports:
      - name: web
        target: 3000
        published: "8080"
      - name: admin
        target: 9000
        published: "9090"
      - name: secure
        target: 9443
        published: "9443"
        app_protocol: https
```

- `app.localhost` uses the first TCP entry in YAML order (`8080` → `3000`).
- `app.8080.localhost` selects the published port `8080`.
- `app.web.localhost` selects the port named `web`.
- `app--p8080.app.localhost` selects published port `8080` through the shared HTTPS listener using the launcher's certificate. Add the selected HTTPS listener port when it is not 443.
- `app--nweb.app.localhost` selects the named `web` port on that HTTPS listener.

Short syntax such as `"8080:3000"` supports default and numeric routes too.
Names used in URLs must be a single hostname label (letters, digits or hyphens);
all-numeric selectors always mean published port numbers. Only TCP ports
published on the running container are routed. Names and YAML order refresh
from the Compose API on the next request after the 100 ms cache expires. Numeric
routes can still use Compose's container port bindings when parsed configuration
is unavailable. Router-generated discovery and availability errors use
`Cache-Control: no-store`, so the browser cannot cache a stale unavailable page.

While the VM or Compose is starting or recovering, browser app requests show
the same black loading screen as container startup and retry the original URL
every two seconds. API requests that accept JSON, writes, and WebSocket upgrades
receive retryable JSON with the runtime status. Failed or stopped runtimes show
their status with a manual retry link.

The Compose UI uses `compose-ui.localhost` on those same HTTP and HTTPS ports.
It shares the application gateway and never needs a separate published port.
The signed Xe Computer app can fetch its selected ports and the limited Compose
project and checkout API at the HTTPS UI origin. Custom HTTPS ports are discovered
through the private management listener before those API requests use HTTPS.
Port 8094 is only the loopback management/API listener; app hostnames on it are
forbidden. Browser navigation to its UI root redirects to the selected public
Compose UI hostname and HTTP port only when that listener is ready; otherwise
it reports 503 instead of serving the UI on 8094 or guessing a fallback port.
On HTTPS, a generated per-installation local authority signs a certificate for
the UI and `*.app.localhost` HTTP application aliases; the certificate needs to be trusted
locally before browsers accept it without warning.

Ports with `app_protocol: https` redirect from the selected shared HTTP port
to the selected shared HTTPS port (80→443 when opted in, otherwise 5196→5194).
Workerd forwards TLS bytes through the guest to the selected
application, which presents its own certificate for the requested `.localhost`
hostname. Ports with `app_protocol: http`, or without an application protocol,
continue through the guest HTTP reverse proxy, also when entered on the shared
HTTPS listener using an `.app.localhost` alias (where Workerd terminates their
TLS). A named or numeric selector for
the default HTTPS port redirects to `app.localhost`; a different HTTPS port
keeps its selector hostname, which must also appear in the application's
certificate.

## Build

From this directory, using Deno 2:

```sh
deno install --frozen
deno task build
deno task build:guest
```

These tasks stage the host text configuration and JavaScript in `dist/host-worker/`
and compile the guest configuration to `dist/guest-worker.bin`. On Linux ARM64,
`deno task build:runtime` also packages the
locked workerd executable and its required runtime libraries in
`dist/guest-runtime/`, with license notices and a checksum manifest.

CI builds the `guest-worker` artifact on Linux ARM64 and includes it in the macOS
app. For a local macOS build, download the artifact from the same source revision
and provide its extracted directory:

```sh
make -C macos BUILD_CONFIG=debug GUEST_ROUTER_ASSET_DIR=/path/to/guest-worker bundle
```

A locally built Linux runtime in `workerd/dist/guest-runtime/` is used by default.
The macOS packaging step injects the guest configuration compiled from the
current checkout into that runtime and regenerates its checksum manifest.

### Host Workerd configuration

The macOS app bundles:

- `Contents/Helpers/workerd`: Cloudflare's runtime executable, similar to Node.js.
- `Contents/Resources/Worker/`: the text configuration and worker scripts.

The launcher generates a per-user certificate, stages the text configuration
beside that certificate, then runs one `workerd serve` process. It supplies the
socket paths and backend addresses at startup; no host config is compiled at
runtime. The guest still uses a Linux `workerd` executable and the precompiled
`guest-worker.bin`.

The public TLS gateway forwards UI and HTTP-app TLS bytes to a private HTTPS
Unix socket in that same process; it passes `app_protocol: https` bytes to the
container unchanged. The generated private key stays out of the signed bundle.

## Lifecycle

Opening an uncreated app or one backed by a created, stopped, or exited container returns a black
loading page with its service name and “Starting…”. The host calls Compose's
`POST /v1.24/start/{project}/container` endpoint with the exact container ID and
config path. Other replicas and services stay stopped. Concurrent requests share
the same start operation. The page retries its original URL every two seconds,
including through the certificate-covered `.app.localhost` HTTPS aliases, and
keeps showing the loader during connection failures while the app starts.
Start failures show the returned Compose error and a retry link; the same error
is logged by Workerd. API requests receive that error in a retryable JSON 503 instead
of an HTML page. Apps without containers are discovered through Compose's project
and service catalogue. Their first container is created and started using the same
single-container endpoint with `service` and `path`, without starting dependencies
or other replicas. The bundled Compose server must support this service form of the
endpoint, build missing service images before creation, and publish creation/start
progress and errors through its existing build activity stream.
Uncreated apps wait until the launcher reports a healthy runtime and the guest
router answers its lightweight health probe before requesting creation or a build.
While waiting, the loader keeps the app name and explains which part is starting.
Existing containers can still start individually without waiting for this build gate.
Direct TLS passthrough apps still own their certificates, so
their container is started on access but their TLS client must retry the connection.

The launcher starts and supervises the host Workerd and the guest router. The guest runs directly in the
VM using bundled runtime files mounted read-only. Its logs are at
`/run/xe-router/workerd.log`. During VM restarts, the host UI stays available and
container routes return 503 until the guest is ready.

Existing VMs created before application routing still need the socket and mount
configuration. Until SmolVM can update exposed sockets, recreate those development
VMs to opt into routing; the launcher never deletes their data automatically.

## Development and verification

For the host development worker set `COMPOSE_UI_ASSETS`, `COMPOSE_SOCKET`, `DOCKER_SOCKET`, and
`ROUTER_SOCKET`, then run `deno task dev`.

The host management worker also has a private connection to the exposed guest
Docker socket for disk usage. `GET /v1.24/disk-usage` reads only image, container,
and volume metadata, caches inventory for 60 seconds, and returns any cached
analysis. `POST /v1.24/disk-usage/scan` performs a read-only `/system/df` query.
Concurrent scans share one request; successful reports last five minutes;
failed scans throttle retries for one minute. Each scan has a 60-second deadline
and cancels the upstream request on timeout. These fixed routes accept no
arbitrary Docker endpoint and never invoke pruning or shell commands.

Run `deno task test:unit` for port selection tests with mocked backends; these
do not start workerd, Docker, or a VM.

The host `startup` worker coordinates the configured `compose_startup_services`
list (empty by default) and app requests from both HTTP and TLS gateways. Swift
publishes `status.json` with a VM `bootId` and `startup-services.json`, then sends
short notifications to the private startup Unix socket. The worker checks VM,
Docker and Compose readiness, starts only the listed services in the background,
and cancels pending starts on shutdown or VM recovery. Its writable disk binding
contains only `boot.json` in the launcher's private `workerd/startup` directory;
it records attempts before dispatch so a workerd restart resumes remaining
entries without repeating them. The coordinator's endpoints are internal and
are not exposed through the public management or application gateways.

The integration suite starts separate host and guest workers linked by a Unix
socket, using disposable Docker/Compose backends. It uses `curl` for TLS requests
and `openssl` for temporary test certificates:

```sh
deno task test:integration node_modules/workerd/bin/workerd /path/to/ui /path/to/compose
deno task test:integration --packaged node_modules/workerd/bin/workerd dist/host-worker /path/to/ui /path/to/compose dist/guest-worker.bin
```

It checks UI availability without the guest, API authentication, streaming,
WebSockets, private-port routing, and Unix-socket replacement after guest failure.
