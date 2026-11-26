# Execution locations

The directory identifies when and where a script executes. Names such as
`verify`, `stage`, or `install` describe the operation within that location.

| Source directory | Execution |
| --- | --- |
| `macos/Build/mac/` | CI/developer Mac: stage components, assemble the VM and app, sign and verify artifacts. These scripts are not shipped. |
| `macos/Build/vm/` | Temporary assembly VM: install the launcher files while constructing its image. Also contains the Smolfile used to pack that image. |
| `macos/Runtime/mac/` | User's Mac: scripts shipped with the installed app. |
| `macos/Runtime/vm/` | User's VM: startup scripts and fixed Docker configuration baked into the image. |
| `macos/Tests/` | Test runners and test source. `Integration/` exercises installation and running services. |
| `workerd/Build/mac/` | Build Mac: prepare the host worker assets. |
| `workerd/Build/linux/` | Linux ARM64 CI runner: package the guest worker executable and libraries. |
| `workerd/Runtime/vm/` | User's VM: guest router configuration and startup script. |

For example, `Build/mac/verify-vm-artifact.ts` checks a VM artifact during
packaging; it does not run in the installed VM. `Build/mac/copy-smol-into-app.sh`
copies staged files into the app bundle; it does not install the app on a user's
Mac. `Tests/run-tests.sh` runs the packaging fixtures and Swift tests.

Deno is a build/test dependency. The installed launcher and its VM do not need
a system Deno installation. Build and VM integration checks run on CI.

`SmolVM.lock` selects the published runtime and verified asset checksums. The
component updater stages that exact runtime and tests manual System/Custom DNS
switching before opening its version-bump PR. PR and release builds repeat the
same test using the pinned runtime. System is the default; changing modes is an
explicit menu action. Startup does not probe runtime capabilities or detect VPNs.
System DNS is a snapshot of the configured host IPv4 nameserver at VM startup,
including loopback DNS servers. Restart Xe Launcher after connecting or
disconnecting WireGuard to refresh it. Both modes use smol's raw DNS forwarding.

These visible source directories do not replace platform-owned layouts:
Swift application source remains under `Sources/macos`, and the app bundle uses
`Contents/MacOS`, `Contents/Helpers`, `Contents/Frameworks`, and
`Contents/Resources`. Build-only scripts must never be copied into the app.
