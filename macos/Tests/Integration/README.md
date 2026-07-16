# macOS installer integration test

`install-from-dmg.sh` performs the real interactive DMG installation. The same
script is intended to run inside a local UTM macOS guest and directly on a
macOS CI runner. UTM and CI should only provision the machine and invoke this
script; they should not duplicate its test steps.

## Destructive changes

Run this only in a disposable test account or VM. At startup the test:

- quits running Xe Computer copies;
- resets TCC permissions for `dev.xe.xecomputer`;
- removes `/Applications/Xe Computer.app`;
- moves `~/Library/Application Support/dev.xe.xecomputer` into `~/.Trash`
  with a timestamp, so accidentally removed data can be recovered;
- detaches stale Xe/Xenon Computer disk-image mounts; and
- runs `brew uninstall --force colima` when Colima is installed.

The launched app installs Colima again as part of the behavior under test.
The permission reset occurs after mounting and registering the DMG's app with
Launch Services, so it also works on a fresh VM where the bundle identifier has
never previously been installed.

## One-time machine setup

1. Use macOS 26.2 or newer. The app declares 26.2 as its minimum version.
2. Install Homebrew and ensure `brew` is available to the test user's shell.
3. Log into the test user at the macOS GUI. UI scripting cannot run from a
   machine that only has a pre-login or SSH session.
4. Open **System Settings → Privacy & Security → Accessibility** and enable the
   program that launches the script. For a manual run this is normally
   Terminal, iTerm, or the terminal application used by the VM. For CI, enable
   the runner application or its UI-test launcher.
5. On the first manual run, macOS may also ask whether that program may control
   **System Events**. Approve it. This grants the Apple Events permission used
   to click the install alert.
6. Ensure the test user can run `sudo` to remove the existing application. A
   dedicated local test account can cache credentials before running; a CI
   account should provide non-interactive sudo.

The test deliberately resets Xe Computer's own permissions on every run. After
the installed copy relaunches, grant its Accessibility request in System
Settings so first-run setup can continue and reinstall Colima. This interaction
is part of the integration test, not a persistent one-time machine grant.

Accessibility and Automation grants belong to the process that invokes
`osascript`. If the test is invoked over SSH, granting Terminal locally does
not grant the SSH session the same permissions. Prefer a logged-in launch agent
or another GUI-session runner whose executable has been approved in advance.

## Build and run

The test expects a signed and notarized distribution DMG because it asserts
both strict code-signature validity and a successful Gatekeeper assessment.
Create it using the normal release configuration:

```sh
make -C macos release
```

Run the test from the repository root:

```sh
macos/Tests/Integration/install-from-dmg.sh
```

To test a DMG from another location, including a downloaded CI artifact:

```sh
DMG_PATH="$HOME/Downloads/Xenon Computer.dmg" \
  macos/Tests/Integration/install-from-dmg.sh
```

The test mounts the DMG read-only, launches its `Xenon Computer.app`, clicks
**Install in Applications**, and verifies:

- installation as `/Applications/Xe Computer.app`;
- relaunch from `/Applications`, not the mounted disk image;
- the expected bundle identifier;
- strict code-signature validity;
- successful Gatekeeper assessment;
- removal of the installed bundle's quarantine attribute; and
- first-run reinstallation of Colima through Homebrew.

## UTM and GitHub Actions

For UTM, copy or mount the repository and DMG into the logged-in guest, then
invoke the script in that guest's approved GUI session. A host wrapper may
start/reset UTM and trigger the guest runner, but must not implement installer
steps itself.

For GitHub Actions, the workflow should similarly contain only checkout,
artifact/build preparation, and one invocation:

```yaml
- name: Run installer integration test
  run: macos/Tests/Integration/install-from-dmg.sh
```

The runner still needs the Accessibility, Automation, Homebrew, sudo, signing,
and GUI-session prerequisites described above. If a hosted runner cannot grant
those UI permissions, use a preconfigured self-hosted runner; do not create a
second CI-specific test implementation.
