# Xe Launcher updates

Xe Launcher uses Sparkle 2.9.4 for signed in-app updates. Stable builds read the
`stable` appcast and `int` prereleases read the `int` appcast. Both feeds are
published on the repository's `updates` branch; release DMGs remain GitHub
Release assets.

Sparkle validates three things before replacing the installed application:

1. the HTTPS appcast feed signature;
2. the Ed25519 signature on the downloaded full DMG or delta; and
3. the application's Apple Developer ID signature.

Sparkle checks automatically without showing its update-check permission
question and downloads updates in the background by default. Downloaded updates
are verified and prepared for installation when the launcher next quits normally;
Sparkle does not force a quit or restart. Users can also choose **Install and
Relaunch** to apply a prepared update immediately. Sparkle's saved user preference
for automatic updates takes precedence over the bundled default.
Users can also choose **Check for Updates…** from stable builds or **Update
(int)** from prerelease builds at any time. Holding Option while the status menu
is open reveals the embedded channel as **Prerelease (int)** or **Release
(stable)** so testers can confirm which feed the installed build uses.
Development builds with the placeholder public key keep the updater disabled.

Interrupted launcher DMG and delta downloads keep their partial files in the
user's Sparkle cache. The downloader resumes after transient network failures
up to three times per download, waiting one, two, then four seconds between attempts.
This applies to the selected archive, including deltas. Each attempt requests the missing bytes from the
release URL, including after a launcher restart or a change of GitHub CDN URL.
If the server returns a replacement archive, the downloader uses the full
response. Sparkle verifies the completed archive before extraction.
An ambiguous HTTP 416 triggers a HEAD metadata check while preserving the
cached bytes. Matching length and validator recover a complete cached archive;
unverifiable metadata triggers a full GET without discarding the saved file
before a successful response. Age-based cleanup excludes the requested partial
and acquires an exclusive file lock before deleting any other expired entry.
These protocol steps run inside one transfer; only actual failures consume the
three automatic retries. Cancellation applies to every step.

Packaging builds Sparkle's Downloader XPC service from the pinned SwiftPM
checkout with the launcher's resumable transfer implementation. A loopback
integration test interrupts two transfers and checks the reassembled archive.

The Xe Computer source asset is stored in application support as
`darc/VERSION/darc.swbn` (for example, `darc/0.0.18/darc.swbn`). Setup checks
the cached bundle against the SHA-256 pinned alongside its version. Pin updates
read `darc.swbn`'s published SHA-256 digest from the trusted GitHub release asset
metadata without downloading or rehashing the bundle. A missing or malformed
digest stops the pin update. An invalid
cached source is deleted; setup downloads a replacement, verifies its checksum in
staging, and atomically moves it into the pinned version's directory.
Once the managed browser is stopped, the launcher
checks the pinned checksum again,
then atomically replaces Chromium's profile-owned `main.swbn`. The versioned
source bundles remain available for rollback, so the launcher does not create
redundant per-profile backups. Chromium uses random per-IWA directory names, so
the launcher finds Xe Computer by its fixed Web Bundle ID, replaces every
matching `main.swbn`, and ignores all other installed IWAs.
Damaged profile bundles use the same atomic replacement path as normal updates,
even when the shim exists. Publication never deletes the destination first and
does not write ownership attributes. The bundle ID marker only identifies the
profile slot; the pinned checksum validates the replacement's complete contents.

Helium is also an independently versioned source asset. The manifest pins its
release version, Chromium version, and the publisher's SHA-256 instead of using
an unversioned `latest/Helium.zip` URL. At startup the launcher stops its
managed browser processes, downloads the pinned Apple-silicon disk image when
the installed Helium version is older or fails deep signature/resource verification, and verifies the checksum,
bundle identity, Developer ID signature, and signing team. A verified engine is
installed at `helium/VERSION/Helium.app`. The complete version directory becomes
visible only after verification, and replacing an existing version uses an
atomic directory swap. Startup deletes invalid managed installations and
abandoned staging/replacement directories. It never restores an old backup;
missing installations go through the normal download and installation flow.
Busy staging directories are logged and left for a later cleanup pass; cleanup
failures do not prevent other setup downloads.
Resolution selects the newest verified engine that satisfies the pin, including
the existing unversioned `Helium.app` when it qualifies, and never
downgrades a newer engine. Browser profiles are stored separately and are not
replaced.

Setup uses the same resumable downloader for Helium and the Xe Computer bundle.
It also allows three automatic resume retries before showing the setup error.
Partial source files stay in the application support directory under `.downloads`
across retries. At startup, setup removes superseded partial files and abandoned
staging files when no setup installation is using the cache.
Each setup pass gets a new cancellation token; cancelling one pass does not
disable later attempts in the same process.

The launcher intentionally does not patch Chromium's protobuf/LevelDB IWA
registry. That registry can therefore continue to display the version used for
the original installation even after the effective profile bundle changes. The
About panel reports both the configured release and the launcher-managed active
bundle by comparing `main.swbn` directly with the pinned versioned source file.
No separate launcher state is written. This mechanism requires neither CDP,
manual update-channel selection, nor a patched Helium build.

The release workflow enforces the same mapping. An `int` launcher can only ship
a Darc GitHub prerelease listed on the IWA manifest's `nightly` channel. A
stable launcher can only ship a non-prerelease Darc release listed on
`default`. Consequently, merging integration work to `main` cannot publish a
stable launcher containing an unpromoted Darc prerelease.

## One-time signing-key setup

There are two related keys, and they have different jobs:

- The **private key** signs update files. It is a secret. Sparkle keeps one
  copy in the current macOS login Keychain under the account label
  `dev.xe.computer`. We also export a repo-local working copy to
  `macos/local-secrets/sparkle-private-key`. Git ignores that file, so it is in
  this checkout but never becomes part of a commit.
- The **public key** verifies those signatures. It is not secret. GitHub Actions
  embeds it in the application so Sparkle can reject updates not signed by the
  matching private key.

Complete these steps manually before the first Sparkle-enabled release.

1. Resolve or build the Swift package so Sparkle's tools exist under
   `.build/artifacts/sparkle/Sparkle/bin/`.
2. From the `macos` directory, create the visible repo-local key directory:

   ```sh
   mkdir -p local-secrets
   chmod 700 local-secrets
   ```

   `mkdir` creates the directory if needed. `chmod 700` permits only your macOS
   user to access it. The directory is not hidden; its secret contents are
   excluded by the repository's `.gitignore`.
3. Generate the key and export its private value into that directory:

   ```sh
   .build/artifacts/sparkle/Sparkle/bin/generate_keys \
     --account dev.xe.computer \
     -x local-secrets/sparkle-private-key

   chmod 600 local-secrets/sparkle-private-key
   ```

   `--account` is only the Keychain label used to find the same key again; it
   is not a username or online account. `-x` writes the private-key export to
   the specified file; export mode does not print the public key. `chmod 600`
   permits only your macOS user to read or change the exported file.

   If a previous export failed because its parent directory did not exist,
   rerunning this command with the same account label should retrieve the key
   already stored in Keychain and export that same key.
4. Print the matching public key separately:

   ```sh
   .build/artifacts/sparkle/Sparkle/bin/generate_keys \
     --account dev.xe.computer \
     -p
   ```

   `-p` means “look up and print the existing public key.” It reads the key
   identified by the same Keychain account label but does not print the private
   key. The printed base64 value is safe to embed in the app. This repository
   reads it from GitHub Actions secrets so both key settings live together.
5. In **GitHub → Repository Settings → Secrets and variables → Actions**, add:

   - Actions **secret** `SPARKLE_PUBLIC_ED_KEY`: the public key printed by
     `generate_keys`. It is not cryptographically secret, but CI reads it from
     Actions secrets and intentionally embeds it in release builds.
   - Actions **secret** `SPARKLE_PRIVATE_KEY`: the exact contents of
     `macos/local-secrets/sparkle-private-key`. This lets the release runner
     sign the appcast and DMG; it must never be committed or logged.

6. Keep an encrypted backup of the private key somewhere independent of this
   checkout. The repo-local ignored copy protects against accidental commits,
   but Git cannot restore it if the checkout or computer is lost.

The release workflow passes the private key to Sparkle's `generate_appcast`
and `sign_update --verify` tools through standard input. It is not written into
the app, appcast, release, logs, or repository. CI fails before publishing if
either GitHub value is missing. The public key is embedded into the release
bundle at build time.

For a local Developer ID release, provide the public value to `make` through
the `SPARKLE_PUBLIC_ED_KEY` environment variable. A release build containing
the placeholder is rejected.

## Release flow

The release workflow:

1. assigns a monotonically increasing `CFBundleVersion`;
2. embeds the channel feed URL and public key;
3. builds, signs, notarizes, and tests the application and DMG;
4. downloads up to three prior DMGs from the same update channel and generates
   direct, signed deltas from those builds to the new notarized application;
5. generates a signed appcast using the fully qualified release tag as
   Sparkle's display version;
6. creates the GitHub release with `Xe-Launcher.dmg`, `appcast.xml`, and every
   generated `.delta` file;
7. updates `stable/appcast.xml` or `int/appcast.xml` on the `updates` branch;
8. downloads and validates the newly published feed; and
9. announces the release only after feed validation succeeds.

Stable and prerelease feeds are deliberately separate, so a stable install can
never discover an `int` build or use one as a delta base. The generated appcast
contains the newest full DMG as a fallback plus up to three deltas from recent
same-channel builds. Sparkle may omit a delta when the source build is
incompatible or the patch would not be meaningfully smaller than the full DMG.

## Verification

Verify a locally assembled application bundle:

```sh
macos/Build/mac/verify-sparkle.sh \
  "macos/dist/Xe Launcher.app"
```

Pass `--release` to additionally reject the public-key placeholder. The check
validates the framework, helper tools, runtime search path, Info.plist security
settings, and all nested code signatures.

Verify a generated or published appcast:

```sh
macos/Build/mac/verify-appcast.sh \
  /path/to/appcast.xml \
  EXPECTED_BUILD_VERSION \
  https://github.com/Agent54/xe-darc-launcher/releases/download/RELEASE/Xe-Launcher.dmg \
  EXPECTED_DISPLAY_VERSION \
  EXPECTED_DELTA_COUNT
```

For the first end-to-end update test, install the first Sparkle-enabled release
manually. Publish a second release on the same channel, choose **Check for
Updates…**, install it, and verify that:

- Sparkle shows the second release and its notes;
- the launcher stops its managed browser processes before replacement;
- the application relaunches from the same Applications folder;
- About displays the second release version; and
- the previously running browser stack is restored by normal launcher startup.

Existing installations from before Sparkle was embedded require one final
manual DMG installation. All subsequent compatible releases can self-update.
