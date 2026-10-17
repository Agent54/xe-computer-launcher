# macOS installer integration test

`cleanup.sh` resets the test machine, `install-from-dmg.sh` performs the real
interactive DMG installation, and `about-version.sh` then verifies that the
About dialog opens in front and displays the installed release version. The
installer test accepts the experimental-software disclaimer when launching from
the DMG, when the installed copy starts, and when testing its later relaunch.
The disclaimer opens after AppKit finishes launching, while launcher state and
runtime components remain uninitialized until it is accepted.
It also accepts the first-run user data storage prompt using the
default `stacks` folder and selects local HTTP/HTTPS ports 80/443. It approves
Xe Launcher's macOS user-Keychain prompt for its generated local HTTPS
certificate and verifies SSL trust before waiting for Compose UI. The
test then relaunches an approved installation with an older registration marker
and verifies that HTTPS and Xe Computer resume without replacing the running
port helper or asking for its approval again. The
`verify-sparkle.sh` and `verify-appcast.sh` scripts validate the embedded
updater and its published feed without changing an installed application. The
same scripts are intended to run inside a local UTM macOS guest and directly on
a macOS CI runner. UTM and CI should only provision the machine and invoke
these scripts; they should not duplicate their behavior.

## Destructive changes

Run destructive cleanup only in a disposable test account or VM. `cleanup.sh`:

- quits running Xe Launcher, Helium, and Xe Computer shim processes;
- unregisters the standard-port helper when the installed app supports CI teardown;
- resets TCC permissions for `dev.xe.computer`;
- removes trust for the generated local HTTPS certificate from the test user's Keychain;
- removes Xe Launcher from `/Applications` and the test user's `~/Applications`;
- moves `~/Library/Application Support/dev.xe.computer` into `~/.Trash`
  with a timestamp, so accidentally removed data can be recovered;
- detaches stale Xe Launcher disk-image mounts.

The release and pull-request workflows run `cleanup-ci.sh` only before
installation. It explicitly disables Trash and permanently removes only the
exact previous Xe test installation, data, and owned generated-shim paths after
removing trust for the prior run's local HTTPS certificate. It refuses to run outside
the launcher's release or integration jobs on the self-hosted macOS ARM64 GitHub Actions runner,
and both cleanup modes refuse targets that contain mounted filesystems or have
symlinked ancestor directories. Manual runs use `cleanup.sh` and retain the
recoverable behavior described above. Trash moves use an atomic rename and fail
across filesystems instead of copying and deleting the source;
ambient environment variables cannot enable permanent cleanup. Failed workspace
build artifacts remain available until the next checkout cleans the workspace.
Timestamped entries created by older workflow versions are not touched and
require one-time runner maintenance.

At CI start, existing launcher and certificate-approval processes are stopped
before removing the old certificate's trust. The trust checks evaluate only the
leaf certificate against macOS's trust stores; supplying the root certificate
would not prove it was trusted in the Keychain. Removal and verification remain
required before deleting the old app data.

After the About-dialog test, both workflows run `cleanup.sh --stop-only` even
if the test fails. It asks Xe Launcher to quit gracefully, then stops any
remaining Workerd, SmolVM, Helium, Xe Computer shim, or pending Xe certificate
approval processes. The installer exit handler stops its authorization helpers
and detaches only the DMG it opened, after verifying the image and device.
CI preserves the installed app, app data (including logs and VM disks), shim
files, DMG file and workspace build artifacts for manual debugging until the
next CI run starts. A detached DMG can be reopened manually, including when
installation failed before the app was copied. End-of-run app shutdown does not
delete the installed app or data, unregister the port helper, or reset permissions;
the installation remains available to inspect until the next run starts.
The launchd helper itself remains registered and keeps 80/443 reserved.

On a fresh VM, `tccutil` may report that the bundle is not registered; the test treats
that as an already-clean permission state and continues.

## One-time machine setup

1. Use macOS 26.2 or newer. The app declares 26.2 as its minimum version.
2. Use a dedicated standard account for the runner and log into that account
   from the Mac's login or user-switching screen, then open the terminal there.
   Changing only the shell user with `su` or `sudo` does not switch the terminal
   application's desktop session. UI scripting cannot run from a machine that
   only has a pre-login or SSH session. Authenticate individual administrator requests
   with a separate administrator account; do not run Actions as that account.
3. Open **System Settings → Privacy & Security → Accessibility** and enable the
   program that launches the script. For a manual run this is normally
   Terminal, iTerm, or the terminal application used by the VM. When CI starts
   with `./run.sh` in that GUI terminal, approve the terminal application too.
   A service or another UI-test launcher can have a different responsible
   process; use the TCC log's attribution to identify it. After enabling it,
   completely quit and reopen that program so its new authorization takes effect.
4. On the first manual run, macOS may also ask whether that program may control
   **System Events**. Approve it. This grants the Apple Events permission used
   to click the install alert. DMG builds also require control of **Finder**
   for the installer window and icon layout. Approve that Automation request
   in the runner's GUI session before running CI.
5. The installer first tries `/Applications/Xe Launcher.app`. If macOS denies
   access, the test accepts the real **Install for This User** prompt and
   verifies `~/Applications/Xe Launcher.app` instead. The runner needs write
   access to its personal Applications folder; it does not need write access to
   all of `/Applications`. Cleanup covers both exact installation paths and
   does not invoke `sudo`. Remove any old installation owned by another account
   separately before provisioning this dedicated test machine.
6. Approve Xe Launcher's background port helper with separate administrator
   credentials when requested.
   After the first signed install selects ports 80/443, macOS shows a
   **Background Items Added** notification. The test opens **System Settings →
   General → Login Items & Extensions** and attempts to enable Xe Launcher under
   **Allow in Background**. If the switch is not clicked automatically, enable
   it in the runner's GUI session and authenticate with the separate
   administrator account. CI cleanup unregisters the helper, so a fresh
   installation may require approval again. A standard account's password
   cannot satisfy an administrator request.
   The optional repository Actions secret `XE_CI_MAC_PASSWORD` supplies only
   a password for the account already selected in a native authorization
   dialog; the authorization script cannot select a separate administrator
   username.
   Leave it unset and complete dialogs manually when CI must not hold those
   credentials. This does not require running the job as an administrator.
   The installer test and CI cleanup use it only for Xe Launcher permission
   and local HTTPS certificate dialogs; it is not passed to the app or printed
   in logs. Without the secret, complete
   any administrator prompt in the runner's GUI session. The test waits for the
   launch daemon and verifies both public ports without restarting the launcher.
   The approved helper remains registered across normal app restarts, reserving
   80/443 until custom ports are selected.

After installation, hold Option while opening the Xe Launcher status menu to
show **Local App Ports** (80/443 or 5196/5194) and **Compose Storage Folder**.
Either change takes effect after quitting and reopening the launcher. Choosing
another storage folder does not move existing projects.

The cleanup deliberately resets Xe Launcher's own permissions on every run. After
the installed copy relaunches, the test grants its Accessibility request in
System Settings. If macOS requires a password to change that switch, the same
optional `XE_CI_MAC_PASSWORD` secret is used. This interaction is part of the
integration test, not a persistent one-time machine grant. CI closes System
Settings before the test and between the background-item and Accessibility
steps, so each macOS permission action opens its intended pane. Xe Launcher
keeps its setup message visible and does not start services until both the
port helper and Accessibility are confirmed.

An existing installation with a saved storage folder but no confirmed port
choice—including older setups that silently saved 5196/5194—gets a one-time
port-choice prompt after updating. If 5196/5194 cannot be
bound, that option is not offered; selecting 80/443 continues through the
normal macOS background-helper approval flow. Choosing **Not Now** leaves
local routing and browser restoration stopped until the next launch.

Accessibility and Automation grants are attributed to the responsible app
reported by TCC, which can be an ancestor of `osascript`. If the test is invoked
over SSH, granting Terminal locally does
not grant the SSH session the same permissions. Prefer a logged-in launch agent
or another GUI-session runner whose executable has been approved in advance.
The raw error may say `osascript is not allowed assistive access`; for a normal
interactive run, approve the terminal application responsible for launching
`/usr/bin/osascript`, then restart that terminal. The test checks this before
performing UI automation.

Validate Finder Automation with the actual `osascript` command in the GUI
terminal used to provision the runner:

```sh
/usr/bin/osascript -e 'tell application "Finder" to get name of startup disk'
```

Allow Finder control if prompted and run the command again. For a service,
also verify the real CI job; a successful Terminal test does not establish the
service's Automation permission. A direct Finder command in Script Editor
is not an equivalent check: Script Editor can use Apple's private Apple Events
entitlement, which a child interpreter does not inherit.

Screen Sharing can show a separate desktop while another account owns the
Mac's main console session. If Finder consent fails without showing a dialog,
check the runner's session with:

```sh
/usr/sbin/scutil <<< 'show State:/Users/ConsoleUser'
```

Within `SessionInfo`, find `kCGSSessionUserNameKey : github-actions-runner`
(or the actual runner account name) and check `kCGSSessionOnConsoleKey`.
Use the runner's main console session (`TRUE`) when provisioning permissions;
the top-level `Name` and `/dev/console` ownership alone do not identify it.
If user switching is stuck with `mSwitchInProgress already`, restart the Mac
normally after saving work and log into the runner account first. This clears
the stuck login processes without making the runner an administrator.

## Build and run

By default, the test expects a signed and notarized distribution DMG because it
asserts both strict code-signature validity and a successful Gatekeeper
assessment. Create it using the normal release configuration:

```sh
make -C macos release
macos/Tests/Integration/verify-sparkle.sh \
  "macos/dist/Xe Launcher.app" --release
```

Reset the machine and run the test from the repository root:

```sh
bash macos/Tests/Integration/cleanup.sh
macos/Tests/Integration/install-from-dmg.sh
macos/Tests/Integration/about-version.sh
```

To test a DMG from another location, including a downloaded CI artifact:

```sh
DMG_PATH="$HOME/Downloads/Xe Launcher.dmg" \
  macos/Tests/Integration/install-from-dmg.sh
```

On a development machine without Developer ID signing and notarization
credentials, build the ad-hoc-signed DMG and run the integration test in
development mode:

```sh
brew install create-dmg # only if create-dmg is not already installed
make -C macos dev-dmg
bash macos/Tests/Integration/cleanup.sh
macos/Tests/Integration/install-from-dmg.sh --dev
```

Those commands are written for the repository root. From inside the `macos`
directory, use `make dev-dmg` and prefix the test scripts with `Tests/Integration/`.

`--dev` retains strict code-signature validation but skips the Gatekeeper
assessments and first-open confirmation waits that require a signed and
notarized distribution build. It launches the disk-image copy directly, removes
quarantine from the installed development copy, then launches that copy through
Launch Services. The latter gives Xe Launcher its own TCC audit identity so the
native Accessibility prompt and System Settings row belong to the app.

The test opens the DMG through Launch Services and waits for Finder's normal
`/Volumes` mount. It identifies that volume from the requested image's exact
file path in disk-image metadata, then locates `Xe Launcher.app` by its bundle
identifier only within that volume. On exit it detaches only an image that was
not attached before the test, after rechecking its image path, mount point and
device. Existing attachments are preserved. It opens the
app through Launch Services, approves the quarantined app's Gatekeeper
**downloaded from the Internet** confirmation with its default **Open** action
when quarantine requires it, chooses the installer alert's default
**Install in Applications**, approves the same system confirmation for the
newly installed copy if macOS shows it again, and verifies:

- installation as `/Applications/Xe Launcher.app`, or the personal
  `~/Applications/Xe Launcher.app` after the app offers and the test accepts its
  permission fallback;
- relaunch from that exact installation path in the test user's account;
- the expected bundle identifier;
- strict code-signature validity;
- successful Gatekeeper assessment in distribution mode;
- removal of the installed bundle's quarantine attribute;
- provisioning and launch of the managed Xe Computer app shim; and
- no macOS App Management request or "prevented from modifying apps" warning.

On success, the installer test writes its selected `INSTALLED_APP` path to
`GITHUB_ENV` for the separate About-dialog step. Manual About tests discover a
personal installation when no system-wide copy exists; an explicit
`INSTALLED_APP` still selects the intended bundle when both copies are present.

The runtime test command also runs focused installation-target regression
checks. They can be run independently without launching an app or cleaning a
real installation:

```sh
bash macos/Tests/Integration/test-install-targets.sh
```

For Accessibility onboarding, the installer test uses the native macOS
permission dialog's **Open System Settings** button before enabling the app in
the Privacy & Security pane. It never opens that pane independently: bypassing
the native dialog would leave an unanswered permission request queued in the
macOS UI, and macOS may terminate the app while that request is pending. If an
interrupted earlier run left more Xe Launcher requests queued, the test accepts
each native dialog before it changes the Accessibility switch.

## UTM and GitHub Actions

For UTM, copy or mount the repository and DMG into the logged-in guest, then
invoke the script in that guest's approved GUI session. A host wrapper may
start/reset UTM and trigger the guest runner, but must not implement installer
steps itself.

For GitHub Actions, the workflow should similarly contain only checkout,
cleanup, artifact/build preparation, and the test invocation:

```yaml
- name: Reset installer integration environment
  run: bash macos/Tests/Integration/cleanup-ci.sh

- name: Run installer integration test
  env:
    DMG_PATH: ${{ github.workspace }}/macos/dist/Xe Launcher.dmg
  run: macos/Tests/Integration/install-from-dmg.sh

- name: Verify version in About dialog
  run: macos/Tests/Integration/about-version.sh
```

The runner still needs the Accessibility, Automation, installation access,
signing, and GUI-session prerequisites described above. Privileged onboarding
requests need separate administrator approval even though the job runs as a
standard user. If a hosted runner cannot grant
those UI permissions, use a preconfigured self-hosted runner; do not create a
second CI-specific test implementation.

## Runners without nested virtualization

Both workflows run host runtime tests with `bash macos/Scripts/test-runtime.sh`
before packaging. The script uses the selected Apple toolchain and supplies
framework and runtime search paths for Swift Testing when using Command Line
Tools. This works around SwiftPM 6.3 passing library search paths for the CLT
framework directory. The suite uses Swift Testing, so the script explicitly
enables that runner and disables the unused XCTest runner, which CLT lacks.

The launcher checks `kern.hv_support` before storage onboarding or SmolVM
startup. Without support, it logs **sub-VM not available** and continues
browser/app startup without container services. The installer test skips that
storage dialog on these machines and `verify-compose-api.sh` skips its
Docker-backed assertion with a warning, so it never waits for a socket that
cannot appear. Installer, signature, updater, and host-only Compose lifecycle
tests continue to run.

Both CI workflows currently set `XE_TEST_SUB_VM_AVAILABLE=0` through the
repository variable `XE_CI_SUB_VM_AVAILABLE` (default `0`). Set that variable
to `1` when moving to hardware runners to restore the Docker-backed assertion.
Local runs detect virtualization automatically unless explicitly disabled with
`XE_TEST_SUB_VM_AVAILABLE=0`. A supported machine with testing enabled still
fails the check if Docker/Compose cannot become ready; startup errors are not
silently converted into test skips.
