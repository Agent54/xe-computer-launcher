# Xe Launcher

Xe Launcher is the entry point for Xe Computer.

## Requirements

### Hardware

- Apple device with MacOS Tahoe.

### Experience

- Familiarity with web code/IDE/agentic environments.

## Setup 

1. Download the [current release](https://github.com/Agent54/xe-darc-launcher/releases/latest).
2. Open the `Xe-Launcher.dmg` file.
3. Drag the `Xe Launcher` icon to the Applications folder.
4. Launch. You will then find the app in your menu bar.
<img width="200" height="377" alt="Screenshot 2026-06-04 at 15 19 12" src="https://github.com/user-attachments/assets/7c35d2cf-eca2-4d0b-84c9-357748dda149" />

> [!NOTE]
> If the package cannot open, launch Terminal and type `xattr -d com.apple.quarantine "Xe-Launcher.dmg"` to bypass Gatekeeper.


## Building From Source Code

see [xe-darc INSTALL.md](https://github.com/Agent54/xe-darc/blob/main/INSTALL.md)

The macOS bundle includes SmolVM and the native macOS ARM64
[Compose server fork](https://github.com/Agent54/compose-server/releases/tag/untagged-5c37175ad9c6770835b7),
pinned with a SHA-256 checksum in `macos/ComposeServer.lock`. Building requires
an authenticated GitHub CLI (or `GH_TOKEN`) with read access to both
`Agent54/smol-compose` and `Agent54/compose-server`. CI uses
`SMOLVM_GITHUB_TOKEN` for both repositories. For offline builds, set
`COMPOSE_SERVER_ASSET_DIR` to a directory containing the pinned
`docker-compose-darwin-aarch64` asset, alongside `SMOLVM_ASSET_DIR` for SmolVM.

On first launch, choose a folder for Compose projects and their files. The
default is `~/Library/Application Support/dev.xe.computer/stacks`; the choice
is saved as `compose_storage_path` in the app's `settings.json`. Choosing
**Not Now** defers runtime startup and asks again on the next launch.
The fork places its Unix socket at `<selected folder>/compose.sock`, so the
full socket path must be shorter than 104 UTF-8 bytes on macOS.

After SmolVM's Docker API becomes ready, the launcher starts the bundled
`Contents/Helpers/docker-compose serve <selected folder>` on the host with
`DOCKER_HOST` set to SmolVM's exposed socket. Compose output appears in System
Logs. Quitting or updating the launcher stops its Compose server.
Readiness checks use native Unix sockets from Swift. If macOS reports no
hypervisor support (including VMs without nested virtualization), startup logs
`sub-VM not available` and skips storage onboarding, SmolVM, and Compose while
continuing the browser and app startup. Other container startup failures are
also logged without blocking the rest of the launcher.

Current CI skips the Docker-backed integration check with a warning. Set the
repository variable `XE_CI_SUB_VM_AVAILABLE=1` when moving to hardware runners
to re-enable it. Host-only Compose tests and installer/signature checks still
run in VM CI. Local installer tests detect `kern.hv_support` automatically;
`XE_TEST_SUB_VM_AVAILABLE=0` explicitly skips their Docker-backed assertion.

To verify the helper and runtime lifecycle locally:

```sh
make -C macos compose-server
cd macos && /usr/bin/xcrun swift test
```



[Download the latest installer from GitHub Releases here](https://github.com/Agent54/xe-darc-launcher/releases/latest).

## Updates

Installed copies use Sparkle for signed in-app updates. Release maintainers
should follow [the updater setup and release guide](macos/UPDATES.md).
