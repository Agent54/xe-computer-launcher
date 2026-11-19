# Launcher VM image

`make bundle` derives this image from SmolVM's verified generic Docker Compose
artifact. `SMOLVM_COMPOSE_ARTIFACT` selects that base for local builds; it is
never a launcher-specific prebuilt image. The recipe lives here because the
router and daemon policy belong to the launcher, while SmolVM owns the generic
Docker/BuildKit image and VM machinery.
Assembly requires virtualization on the Apple Silicon build Mac; unchanged
inputs reuse the cached image without booting a build VM.

The build installs the compiled guest router, its Linux workerd executable and
libraries, and the fixed Docker daemon configuration. It replaces DinD's
recursive PID cleanup with cleanup of `/run/docker.pid`. Docker's upstream
networking setup stays intact; its bundled Tini becomes the init for both
services. No host PATH shim or `/etc/docker`
mount is needed, and arbitrary host `daemon.json` overrides are not supported.

The image entrypoint starts Docker and the router concurrently. If either exits,
it stops the other and fails the workload, allowing the launcher's existing VM
recovery to observe the failure. Signals stop both processes. Router output goes
to the workload console and the existing host log collector. BuildKit still
starts only for a build request.

The host boundary remains:

- Docker API: guest `/var/run/docker.sock`, exposed to the host Docker socket.
- Application routing: guest `/run/xe-router/workerd.sock`, exposed to the host
  workerd socket. The router uses only guest Docker discovery and container IPs.
- Project files: the configured host stacks directory, mounted at `/stacks`.
- Host workerd, UI assets, TLS certificates, Compose server, and maintenance
  controls remain on the Mac.

Image assembly uses only local inputs. Its cache key includes the verified base
metadata, router checksums and recipe, so unchanged inputs reuse the packed
image. The VM's labels record this input identity; a changed recipe, base or
router cannot silently reuse an old persistent VM. Build state remains under
`.build/launcher-vm`; only a temporary short
socket-path symlink uses `/tmp`. The build does not boot Docker or import
BuildKit into the image. VM-format mismatches require explicit recreation;
the launcher does not modify or migrate existing VM contents.
