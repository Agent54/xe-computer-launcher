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


## Compose

On first launch, choose a folder for your Compose projects. The IWA UI provides
access to Compose. Its server runs on your Mac and stays available during VM
restarts; container operations resume when the VM is ready.

Access running services at `http://<service>.localhost:5196/`. Use
`<service>_<project>` when projects share a service name. The default is the first
TCP port in the Compose `ports` list. Select a specific published port with
`<service>.8080.localhost`, or a [named port](workerd/README.md#port-routes) with
`<service>.web.localhost` (both on port 5196).

The container VM uses at least 4096 MiB of elastic memory. Advanced users can
raise the limit by setting `container_vm_memory_mib` in
`~/Library/Application Support/dev.xe.computer/settings.json` (up to 32768) and
restarting Xe Launcher. The launcher monitors Docker after startup and performs
a bounded VM restart if the daemon becomes unavailable; the menu status and
Compose API expose whether recovery was caused by an out-of-memory event.

## Building from source

Follow the [development setup](https://github.com/Agent54/xe-darc/blob/main/INSTALL.md).
You also need Deno 2 and an authenticated GitHub CLI with read access to
`Agent54/smol-compose`, `Agent54/compose-server`, and `Agent54/compose-ui`.

For a local macOS build, download and extract the `guest-worker` artifact from
a CI run for the same source revision:

```sh
make -C macos BUILD_CONFIG=debug GUEST_ROUTER_ASSET_DIR=/path/to/guest-worker bundle
```

CI builds the guest worker and macOS app together. See [worker development](workerd/README.md)
and [integration tests](macos/Tests/Integration/README.md) for contributor details.

## Updates

Installed copies use Sparkle for signed in-app updates. Release maintainers
should follow [the updater setup and release guide](macos/UPDATES.md).
