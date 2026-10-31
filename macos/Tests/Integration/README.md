# macOS integration testing

The installer suite exercises the real DMG and installed application in a
logged-in macOS desktop. UTM and GitHub Actions should provision the machine
and invoke these scripts, not maintain separate installer automation.

## Test profiles

| Profile | Requirements and purpose |
| --- | --- |
| `--standard-user` | Signed distribution build, ports 5196/5194 and a persistent Accessibility grant. Used by CI without registering a privileged helper. |
| Default | Manual fresh onboarding, ports 80/443 and privileged-helper approval. Requires an operator who can authenticate administrator requests. |
| `--dev` | Ad-hoc development DMG. Retains strict signature validation but skips distribution-only Gatekeeper and first-open checks. |

Use a dedicated test account or disposable VM. Cleanup changes installed apps,
launcher data, certificate trust and, in the default profile, privacy grants.
Do not share the CI account with interactive work or concurrent GUI jobs:
stale-authorization cleanup can dismiss other pending prompts in that account.

## Cleanup and retained evidence

| Command | Intended use |
| --- | --- |
| `cleanup.sh` | Manual reset. Removes installations and local CA trust, resets app permissions, and moves launcher data to a timestamped Trash entry. |
| `cleanup.sh --preserve-permissions` | Manual reproduction of the CI profile. Retains the signed installation and privacy grants while resetting data and local CA trust. |
| `cleanup-ci.sh` | CI-job-only reset. Retains the signed app and grants, but permanently removes the previous run's exact app-data and owned shim paths. |
| `cleanup.sh --stop-only` | End-of-run shutdown. Preserves installations, data, permissions and build artifacts for inspection. |

Manual Trash moves require the source and Trash to be on the same filesystem.
Cleanup refuses symlinked ancestors and paths containing mounted filesystems.
Old timestamped entries from earlier CI workflows require separate runner
maintenance.

Removing the previous local CA's trust must finish before deleting its app
data. A trust failure preserves that data for diagnosis. Testing the old leaf
certificate is important: supplying the root as a trusted anchor would not
prove that Keychain trust was removed.

Both workflows preserve failed-run evidence until the next run starts.
Reopen the retained DMG or inspect the installed bundle and launcher data there.
The manual 80/443 profile can leave its helper reserving those ports; unregister
it or select custom ports before reusing the machine for other work.

## One-time runner setup

1. Use macOS 26.2 or newer and a dedicated **standard** account. Log into its
   desktop from the Mac's login or user-switching screen. `su`, `sudo` and SSH
   do not provide the same desktop session or permission attribution.
2. Grant Accessibility to the application responsible for launching the tests,
   normally the GUI terminal running the Actions runner. Quit and reopen it
   after granting access. A launch agent or service can have a different TCC
   identity; provision and verify the actual execution context.
3. Approve that context's Automation access to **System Events** and **Finder**.
   Finder access is required for DMG formatting as well as installation.
4. Install a Developer ID signed Xe Launcher, keep ports 5196/5194, and approve
   **Xe Launcher** under Privacy & Security → Accessibility once. Quit it
   normally. Unattended CI retains this grant and refreshes the same installed
   bundle; it does not enable the Accessibility switch itself.
5. Keep one installation owned and writable by the runner. The personal
   `~/Applications` location is supported when `/Applications` is unavailable.
   Remove conflicting installations owned by another account separately.
   Replacement builds must match the retained bundle's signing identity.
   Ad-hoc builds cannot use persistent-permission mode.
6. Optionally configure `XE_CI_MAC_PASSWORD` as a repository Actions secret for
   the runner account's native user-Keychain certificate dialogs. Without it,
   handle those dialogs manually. It cannot satisfy requests for a different
   administrator account.

A runner without these permissions needs interactive provisioning; use a
preconfigured self-hosted runner if the hosted environment cannot supply them.

## Build and run

Commands below run from the repository root. Distribution tests require the
normal signed, notarized release and its configured credentials:

```sh
make -C macos release
macos/Tests/Integration/verify-sparkle.sh \
  "macos/dist/Xe Launcher.app" --release
```

For manual fresh onboarding:

```sh
bash macos/Tests/Integration/cleanup.sh
macos/Tests/Integration/install-from-dmg.sh
macos/Tests/Integration/about-version.sh
```

To reproduce the Standard-user CI profile with its retained installation:

```sh
bash macos/Tests/Integration/cleanup.sh --preserve-permissions
macos/Tests/Integration/install-from-dmg.sh --standard-user
macos/Tests/Integration/about-version.sh
```

Set `DMG_PATH` to test an artifact from another location. Set `INSTALLED_APP`
when the About test must target a particular installation.

For local development without distribution credentials:

```sh
make -C macos dev-dmg
bash macos/Tests/Integration/cleanup.sh
macos/Tests/Integration/install-from-dmg.sh --dev
```

The development DMG requires `create-dmg`. After inspecting a run, stop its
processes without discarding the evidence:

```sh
bash macos/Tests/Integration/cleanup.sh --stop-only
```

For host runtime tests, use the shared build graph:

```sh
make -C macos BUILD_CONFIG=debug test
```

The test wrapper uses the selected Apple toolchain and handles Swift Testing's
framework search paths under Command Line Tools. The standalone
`settings-termination.sh`, `test-install-targets.sh` and
`test-ci-security-agent-cleanup.sh` regression checks do not clean a real
installation. The settings check is built and run by the runtime suite and still
needs a logged-in GUI session; its standalone script reuses that built fixture
(`BUILD_CONFIG=debug` by default).

## Permission troubleshooting

TCC grants belong to the responsible application, which can be an ancestor of
`osascript`. Approving Terminal does not approve an SSH session or service.
Use TCC log attribution to identify the responsible process. A successful
Script Editor test is insufficient because its private Apple Events
entitlement is not inherited by a child interpreter.

Test Finder Automation from the same GUI terminal that launches the runner:

```sh
/usr/bin/osascript -e 'tell application "Finder" to get name of startup disk'
```

Screen Sharing may show a desktop that is not the Mac's main console session.
If consent fails without displaying a prompt, inspect:

```sh
/usr/sbin/scutil <<< 'show State:/Users/ConsoleUser'
```

Within `SessionInfo`, find the runner's `kCGSSessionUserNameKey` and verify
`kCGSSessionOnConsoleKey` is `TRUE`; the top-level name or `/dev/console`
ownership alone is insufficient. If switching is stuck with
`mSwitchInProgress already`, save work, restart the Mac normally, and log into
the runner account first.

For fresh Accessibility onboarding, enter System Settings through the native
permission dialog. Opening the pane independently can leave a pending request
that causes macOS to terminate the app. Stale authorization cleanup cannot fix
a locked desktop, missing GUI session or revoked permission.

## Virtualization and runtime diagnostics

Host-only installation, updater, browser and Compose tests can run without
nested virtualization. Docker-backed checks need `kern.hv_support=1` in the
runner's kernel. The Actions variable `XE_CI_SUB_VM_AVAILABLE` (locally,
`XE_TEST_SUB_VM_AVAILABLE`) can disable those checks with `0`; `1` still
requires kernel support. When enabled on a supported machine, failure to start
Docker is a test failure, not a skip.

Runtime sockets use the short alias `~/.xe/run` for
`~/Library/Application Support/dev.xe.computer` because macOS Unix-socket paths
have a 103-byte UTF-8 budget, including SmolVM's internal sockets. A conflicting
item at that alias must be resolved explicitly rather than replaced blindly.
The Compose API socket is `~/.xe/run/compose.sock`, outside the shared project
folder. Inspect launcher logs and the final backend error when readiness fails.
