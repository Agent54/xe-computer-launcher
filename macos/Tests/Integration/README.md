# macOS installer integration test

`cleanup.sh` resets the test machine, `install-from-dmg.sh` performs the real
interactive DMG installation, and `about-version.sh` then verifies that the
About dialog opens in front and displays the installed release version. The
same scripts are intended to run inside a local UTM macOS guest and directly on
a macOS CI runner. UTM and CI should only provision the machine and invoke
these scripts; they should not duplicate their behavior.

## Destructive changes

Run this only in a disposable test account or VM. `cleanup.sh`:

- quits running XE Launcher copies;
- resets TCC permissions for `dev.xe.computer`;
- removes `/Applications/XE Launcher.app`;
- moves `~/Library/Application Support/dev.xe.computer` into `~/.Trash`
  with a timestamp, so accidentally removed data can be recovered;
- detaches stale XE Launcher disk-image mounts; and
- runs `brew uninstall --force colima` when Colima is installed.

The launched app installs Colima again as part of the behavior under test. On a
fresh VM, `tccutil` may report that the bundle is not registered; the test treats
that as an already-clean permission state and continues.

## One-time machine setup

1. Use macOS 26.2 or newer. The app declares 26.2 as its minimum version.
2. Install Homebrew and ensure `brew` is available to the test user's shell.
3. Log into the test user at the macOS GUI. UI scripting cannot run from a
   machine that only has a pre-login or SSH session.
4. Open **System Settings → Privacy & Security → Accessibility** and enable the
   program that launches the script. For a manual run this is normally
   Terminal, iTerm, or the terminal application used by the VM. For CI, enable
   the runner application or its UI-test launcher. After enabling it, completely
   quit and reopen that program so its new TCC authorization takes effect.
5. On the first manual run, macOS may also ask whether that program may control
   **System Events**. Approve it. This grants the Apple Events permission used
   to click the install alert.
6. Ensure the test user can run `sudo` to remove the existing application. A
   dedicated local test account can cache credentials before running; a CI
   account should provide non-interactive sudo.

The cleanup deliberately resets XE Launcher's own permissions on every run. After
the installed copy relaunches, grant its Accessibility request in System
Settings so first-run setup can continue and reinstall Colima. This interaction
is part of the integration test, not a persistent one-time machine grant.

Accessibility and Automation grants belong to the process that invokes
`osascript`. If the test is invoked over SSH, granting Terminal locally does
not grant the SSH session the same permissions. Prefer a logged-in launch agent
or another GUI-session runner whose executable has been approved in advance.
The raw error may say `osascript is not allowed assistive access`; for a normal
interactive run, approve the terminal application responsible for launching
`/usr/bin/osascript`, then restart that terminal. The test checks this before
performing UI automation.

## Build and run

By default, the test expects a signed and notarized distribution DMG because it
asserts both strict code-signature validity and a successful Gatekeeper
assessment. Create it using the normal release configuration:

```sh
make -C macos release
```

Reset the machine and run the test from the repository root:

```sh
bash macos/Tests/Integration/cleanup.sh
macos/Tests/Integration/install-from-dmg.sh
macos/Tests/Integration/about-version.sh
```

To test a DMG from another location, including a downloaded CI artifact:

```sh
DMG_PATH="$HOME/Downloads/XE Launcher.dmg" \
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
Launch Services. The latter gives XE Launcher its own TCC audit identity so the
native Accessibility prompt and System Settings row belong to the app.

The test opens the DMG through Launch Services, waits for Finder's normal
`/Volumes` mount, locates `XE Launcher.app` by its bundle identifier, opens the
app through Launch Services, approves the quarantined app's Gatekeeper
**downloaded from the Internet** confirmation with its default **Open** action
when quarantine requires it, chooses the installer alert's default
**Install in Applications**, approves the same system confirmation for the
newly installed copy if macOS shows it again, and verifies:

- installation as `/Applications/XE Launcher.app`;
- relaunch from `/Applications`, not the mounted disk image;
- the expected bundle identifier;
- strict code-signature validity;
- successful Gatekeeper assessment in distribution mode;
- removal of the installed bundle's quarantine attribute; and
- first-run reinstallation of Colima through Homebrew;
- provisioning and launch of the managed Darc app shim; and
- no macOS App Management request or "prevented from modifying apps" warning.

For Accessibility onboarding, the installer test uses the native macOS
permission dialog's **Open System Settings** button before enabling the app in
the Privacy & Security pane. It never opens that pane independently: bypassing
the native dialog would leave an unanswered permission request queued in the
macOS UI, and macOS may terminate the app while that request is pending. If an
interrupted earlier run left more XE Launcher requests queued, the test accepts
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
  run: bash macos/Tests/Integration/cleanup.sh

- name: Run installer integration test
  env:
    DMG_PATH: ${{ github.workspace }}/macos/dist/XE Launcher.dmg
  run: macos/Tests/Integration/install-from-dmg.sh

- name: Verify version in About dialog
  run: macos/Tests/Integration/about-version.sh
```

The runner still needs the Accessibility, Automation, Homebrew, sudo, signing,
and GUI-session prerequisites described above. If a hosted runner cannot grant
those UI permissions, use a preconfigured self-hosted runner; do not create a
second CI-specific test implementation.
