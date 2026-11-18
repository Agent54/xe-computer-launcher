#!/usr/bin/env python3
"""Exercise bundled engines and byte integrity through a disposable VM's socket.

No retries: a single truncated/corrupt upload fails the run and preserves logs.
Use --baseline to compare socket uploads against an older bundle.
"""
import argparse
import gzip
import hashlib
import http.client
import io
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tarfile
import tempfile
import time


class UnixHTTP(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=120)
        self.path = str(path)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


def request(path, method, route, body=None, headers=None, chunked=False):
    connection = UnixHTTP(path)
    try:
        connection.request(method, route, body=body, headers=headers or {}, encode_chunked=chunked)
        response = connection.getresponse()
        data = response.read()
        if response.status >= 300:
            raise RuntimeError(f"{method} {route}: {response.status}: {data[:2000]!r}")
        return data
    finally:
        connection.close()


def tar_payload(payload):
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode="w") as archive:
        info = tarfile.TarInfo("payload.bin")
        info.size = len(payload)
        archive.addfile(info, io.BytesIO(payload))
    return data.getvalue()


def check_upload(path, index):
    # Cross gzip, HTTP chunk, vsock buffer and 1 MiB boundaries. Random data
    # prevents compression from reducing this to a tiny transport test.
    size = [65537, 1048577, 64 * 1024 * 1024 + 17][index % 3]
    payload = os.urandom(size)
    expected = hashlib.sha256(payload).hexdigest()
    body = tar_payload(payload)
    compressed = index % 2 == 0
    if compressed:
        body = gzip.compress(body)
    chunked = index % 4 < 2
    headers = {"Content-Type": "application/x-tar"}
    if chunked:
        def chunks():
            offset = 0
            sizes = [7, 4093, 65537, 131071]
            while offset < len(body):
                amount = sizes[(offset // 7) % len(sizes)]
                yield body[offset:offset + amount]
                offset += amount
        upload = chunks()
    else:
        upload = body
        headers["Content-Length"] = str(len(body))
    # Import uses Docker's tar/gzip reader but does not depend on the legacy
    # builder remaining available in newer Engine versions.
    output = request(path, "POST", "/v1.51/images/create?fromSrc=-&repo=xe-upload-probe", upload, headers, chunked)
    for line in output.splitlines():
        message = json.loads(line)
        if message.get("error"):
            raise RuntimeError(message["error"])
    image = json.loads(request(path, "GET", "/v1.51/images/xe-upload-probe/json"))["Id"]
    try:
        exported = request(path, "GET", f"/v1.51/images/{image}/get")
        with tarfile.open(fileobj=io.BytesIO(exported)) as archive:
            manifest = json.load(archive.extractfile("manifest.json"))
            layer = archive.extractfile(manifest[0]["Layers"][-1]).read()
        with tarfile.open(fileobj=io.BytesIO(layer), mode="r:*") as archive:
            actual = hashlib.sha256(archive.extractfile("payload.bin").read()).hexdigest()
        assert actual == expected, f"Upload {index}: payload checksum mismatch"
    finally:
        request(path, "DELETE", "/v1.51/images/xe-upload-probe?force=1")
    print(f"PASS upload {index}: {size} bytes, gzip={compressed}, chunked={chunked}", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--artifact", type=Path, help="Explicit local SmolVM image to validate before packaging")
    parser.add_argument("--baseline", action="store_true")
    args = parser.parse_args()
    macos = Path(__file__).resolve().parents[2]
    state = macos / ".build" / "builder-runtime-tests"
    state.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix="run-", dir=state))
    # macOS Unix sockets have a 104-byte limit; only the short symlink is in /tmp.
    short_parent = Path(tempfile.mkdtemp(prefix="xe-build-", dir="/tmp"))
    short = short_parent / "s"
    short.symlink_to(root, target_is_directory=True)
    helpers = args.bundle / "Contents/Helpers/SmolRuntime"
    resources = args.bundle / "Contents/Resources/SmolRuntime"
    tools = args.bundle / "Contents/Resources/ContainerTools"
    plugin = args.bundle / "Contents/Resources/ContainerTools/cli-plugins/docker-buildx"
    docker_socket = short / "docker.sock"
    home = root / "home"
    templates = home / ".smolvm"
    templates.mkdir(parents=True)
    for name in ["storage-template.ext4.zst", "overlay-template.ext4.zst"]:
        shutil.copy2(resources / name, templates / name)
    env = {
        "HOME": str(home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "SMOLVM_DATA_DIR": str(short / "data"), "SMOLVM_LIB_DIR": str(helpers / "lib"),
        "DYLD_LIBRARY_PATH": str(helpers / "lib"), "SMOLVM_AGENT_ROOTFS_TAR": str(resources / "agent-rootfs.tar"),
    }
    log = open(root / "commands.log", "w")
    created = False

    def run(command, timeout=240, environment=env, check=True):
        result = subprocess.run([str(x) for x in command], env=environment, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=timeout, text=True)
        log.write("$ " + " ".join(map(str, command)) + "\n" + result.stdout + "\n")
        log.flush()
        if check and result.returncode:
            raise RuntimeError(result.stdout[-8000:])
        return result.stdout

    def machine(*command, **kwargs):
        return run([helpers / "smolvm-bin", "machine", *command], **kwargs)

    def ready():
        for _ in range(90):
            try:
                if request(docker_socket, "GET", "/_ping") == b"OK":
                    return
            except (OSError, http.client.HTTPException):
                pass
            time.sleep(1)
        raise RuntimeError("Docker did not become ready")

    try:
        arguments = ["create", "--name", "xe-builder-test", "--from", str(args.artifact or resources / "docker-compose.smolmachine"),
                     "--net-backend", "virtio-net", "--mem", "6144", "--cpus", "4", "--storage", "20",
                     "--expose-socket", f"/var/run/docker.sock:{docker_socket}"]
        if not args.baseline:
            configuration = root / "docker-config"
            configuration.mkdir()
            (configuration / "daemon.json").write_text(json.dumps({
                "pidfile": "/run/docker.pid", "restart": False,
                "features": {"containerd-snapshotter": False}, "builder": {"gc": {"enabled": False}},
            }))
            arguments += ["--volume", f"{configuration}:/etc/docker:ro"]
        machine(*arguments)
        created = True
        started = time.monotonic()
        machine("start", "--name", "xe-builder-test")
        ready()
        print(f"VM Docker ready in {time.monotonic() - started:.2f}s", flush=True)
        version = json.loads(request(docker_socket, "GET", "/version"))["Version"]
        print(f"Docker {version}; diagnostics: {root}", flush=True)
        for index in range(12):
            check_upload(docker_socket, index)
        if not args.baseline:
            values = dict(line.split("=", 1) for line in (tools / "ContainerTools.lock").read_text().splitlines())
            assert version == values["DOCKER_VERSION"]
            client_env = dict(env, DOCKER_HOST=f"unix://{docker_socket}", DOCKER_CONFIG=str(root / "docker-client"),
                              BUILDX_CONFIG=str(root / "docker-client/buildx"), DOCKER_BUILDKIT="1", BUILDX_BUILDER="xe",
                              XE_SMOLVM_HOME=str(home), XE_SMOLVM_DATA_DIR=env["SMOLVM_DATA_DIR"], XE_SMOLVM_MACHINE="xe-builder-test")
            (root / "docker-client").mkdir(exist_ok=True)
            (root / "docker-client/config.json").write_text(json.dumps({"cliPluginsExtraDirs": [str(plugin.parent)]}))
            run([plugin, "version"], environment=client_env)
            run([plugin, "docker-cli-plugin-metadata"], environment=client_env)
            machine("exec", "--name", "xe-builder-test", "--", "/usr/local/share/xe-builder/cache.sh", "prune", "--builder", "xe", "--force")
            assert json.loads(request(docker_socket, "GET", "/v1.51/containers/json?all=1")) == []
            images = json.loads(request(docker_socket, "GET", "/v1.51/images/json"))
            assert not any(image["Id"] == values["BUILDKIT_IMAGE_ID"] for image in images)
            print("PASS idle VM, plugin discovery and maintenance do not import or start BuildKit", flush=True)
            context = root / "context"
            context.mkdir()
            (context / "Dockerfile").write_text("FROM scratch\nCOPY payload.bin /payload.bin\n")
            for boot in range(2):
                if boot:
                    machine("stop", "--name", "xe-builder-test")
                    started = time.monotonic()
                    machine("start", "--name", "xe-builder-test")
                    ready()
                    builder = json.loads(request(docker_socket, "GET", "/v1.51/containers/buildx_buildkit_xe0/json"))
                    assert not builder["State"]["Running"]
                    assert builder["HostConfig"]["RestartPolicy"]["Name"] == "no"
                    machine("exec", "--name", "xe-builder-test", "--", "/usr/local/share/xe-builder/cache.sh", "prune", "--builder", "xe", "--force")
                    assert not json.loads(request(docker_socket, "GET", "/v1.51/containers/buildx_buildkit_xe0/json"))["State"]["Running"]
                    print(f"PASS restart and maintenance leave BuildKit stopped ({time.monotonic() - started:.2f}s)", flush=True)
                for attempt in range(3):
                    payload = os.urandom(8 * 1024 * 1024 + 17)
                    (context / "payload.bin").write_bytes(payload)
                    output = root / f"output-{boot}-{attempt}"
                    run([plugin, "build", "--builder", "xe", "--progress", "plain", "--output", f"type=local,dest={output}", context], environment=client_env)
                    assert (output / "payload.bin").read_bytes() == payload, "BuildKit output is corrupted"
                    print(f"PASS BuildKit upload, boot={boot}, attempt={attempt}", flush=True)
            run([plugin, "build", "--builder", "xe", "--load", "--tag", "xe-builder-probe", context], environment=client_env)
            request(docker_socket, "GET", "/v1.51/images/xe-builder-probe/json")
            print("PASS BuildKit result loaded into Docker", flush=True)
            # COPY --link requires BuildKit, giving positive evidence beyond optional labels.
            (context / "Dockerfile").write_text("FROM scratch\nCOPY --link payload.bin /payload.bin\n")
            (context / "compose.yaml").write_text("name: xe-build-probe\nservices:\n  probe:\n    build: .\n    image: xe-compose-build-probe\n")
            run([args.bundle / "Contents/Helpers/docker-compose", "-f", context / "compose.yaml", "build"], environment=client_env)
            image = json.loads(request(docker_socket, "GET", "/v1.51/images/xe-compose-build-probe/json"))
            assert (image["Config"].get("Labels") or {}).get("com.docker.compose.image.builder") != "classic"
            print("PASS bundled Compose uses BuildKit", flush=True)
            actual = machine("exec", "--name", "xe-builder-test", "--", "/usr/local/bin/docker", "exec", "buildx_buildkit_xe0", "buildkitd", "--version")
            assert f'v{values["BUILDKIT_VERSION"]} ' in actual
            disabled = run([args.bundle / "Contents/Helpers/docker-compose", "-f", context / "compose.yaml", "build"],
                           environment=dict(client_env, DOCKER_BUILDKIT="0"), check=False)
            assert "classic builds are disabled" in disabled
            print("PASS Compose rejects the classic builder", flush=True)
        print("PASS: no retries or corrupted uploads", flush=True)
    finally:
        if created:
            machine("stop", "--name", "xe-builder-test")
        log.close()
        short.unlink()
        short_parent.rmdir()
        print(f"Preserved disposable VM and diagnostics in {root}", flush=True)


if __name__ == "__main__":
    main()
