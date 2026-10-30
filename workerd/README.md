# Host gateway and guest router

## Architecture

Workerd bridges macOS-hosted Compose and browser services to applications in
SmolVM. The host UI and API must remain available independently of the VM.

- The **management gateway** is separate from the **application gateway** so a
  forged Host header on the management socket cannot enter app routing.
- The **host** owns project discovery, service startup and public HTTP/TLS
  listeners. The **guest router** validates live container bindings and reaches
  the container's private port. Their connection is a Unix socket exposed by
  SmolVM.
- One **startup coordinator** serves configured startup and on-demand requests
  from both HTTP and TLS. Persistent per-boot state prevents Workerd restarts
  from replaying starts. Project/config identity must remain part of discovery
  and startup decisions: different checkouts can share a Compose project name.

The host uses text configuration so the launcher can supply local certificates
and backend addresses without compiling at runtime. The guest uses a compiled
configuration and a Linux ARM64 runtime mounted read-only into the VM.

Existing development VMs created before application routing need the routing
mounts and exposed sockets. Until SmolVM can update those sockets, recreate
such VMs to enable routing; preserve their data separately.

## Port routes

Compose UI and apps share the selected public HTTP/HTTPS ports. Port 8094 is
private management and must not be used for application URLs.

For a service named `app`, these hostnames select its published TCP ports:

| Hostname | Selection |
| --- | --- |
| `app.localhost` | First TCP entry in Compose YAML order |
| `app.8080.localhost` | Published port 8080, not the container's target port |
| `app.web.localhost` | Port named `web` using Compose's [long port syntax](https://docs.docker.com/reference/compose-file/services/#ports) |
| `app--p8080.app.localhost` | Published port 8080 through the shared HTTPS listener |
| `app--nweb.app.localhost` | Named port `web` through the shared HTTPS listener |

Use `app_<project>` when projects share a service name. Include the selected
listener port when it is not 80 or 443. Port names must be hostname labels;
numeric selectors always mean published port numbers.

Default and named routes remain stable with Docker-assigned host ports; numeric
routes can change after recreation. Opening an app may create or start its
container without starting dependencies or other replicas. This requires the
bundled Compose server's single-container startup API, including its service
form for containers that do not exist yet.

### TLS ownership

For HTTP containers, Workerd terminates HTTPS on `.app.localhost` aliases using
the launcher's local CA. The UI uses the same CA at `compose-ui.localhost`.
Private keys belong in per-user launcher state, outside the signed bundle.

For ports marked `app_protocol: https`, Workerd passes TLS through to the
container. Its certificate must cover the requested `.localhost` hostname,
including a port selector when one is used. These apps can start on access,
but their TLS client must retry while the container starts.

## Browser automation

CDP is available at the Compose UI's HTTPS origin under `/devtools-api/`,
independently of the VM. `/json/list` supplies page targets and
`/json/version` the browser WebSocket URL. Discover the selected origin through
Compose rather than assuming the Vite development proxy or a fixed port.

The launcher owns Helium's debug pipe; Workerd owns the HTTP/WebSocket API and
per-client browser sessions. Both share the private
`~/.xe/run/sockets/cdp.sock`. Native CDP clients currently have full browser
access: IWA/controlled-frame rewriting, agent permissions and audit logging
are not implemented.

The `Xe` CDP domain reserves future launcher APIs. Its handlers are stubs,
not permission grants or browser filesystem handles. Future implementations
must derive the requesting tab, origin and partition from the validated
session before enforcing permissions.

DevTools is packaged locally to avoid a runtime dependency on Chromium's
hosted frontend. See [vendoring and theme maintenance](../devtools/README.md).

## Build

From this directory, with Deno 2 and Python 3:

```sh
deno install --frozen
deno task build
deno task build:guest
```

On Linux ARM64, `deno task build:runtime` packages the guest runtime for macOS
distribution. Local launcher builds need that CI artifact from the same source
revision; see the [launcher build instructions](../README.md#building-from-source).

For host development, set `COMPOSE_UI_ASSETS`, `COMPOSE_SOCKET`,
`DOCKER_SOCKET` and `ROUTER_SOCKET`, then run `deno task dev`.

## Verification

`deno task test:unit` needs no VM or Docker daemon. The integration suite uses
real host/guest Workerd processes and disposable Docker/Compose backends;
it also needs `curl`, `openssl`, extracted Compose UI assets and the Compose
binary:

```sh
deno task test:integration node_modules/workerd/bin/workerd /path/to/ui /path/to/compose
deno task test:integration --packaged node_modules/workerd/bin/workerd dist/host-worker /path/to/ui /path/to/compose dist/guest-worker.bin
```

Guest router logs are at `/run/xe-router/workerd.log` inside the VM.
