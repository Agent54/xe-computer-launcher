# XE Launcher updates

XE Launcher uses Sparkle 2.9.4 for signed in-app updates. Stable builds read the
`stable` appcast and `int` prereleases read the `int` appcast. Both feeds are
published on the repository's `updates` branch; release DMGs remain GitHub
Release assets.

Sparkle validates three things before replacing the installed application:

1. the HTTPS appcast feed signature;
2. the Ed25519 signature on the downloaded DMG; and
3. the application's Apple Developer ID signature.

Sparkle asks on the second installed launch whether automatic checks should be
enabled; automatic installation defaults to off. Users can always choose
**Check for Updates…** from the status menu. Development builds with the
placeholder public key keep the updater disabled.

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
4. generates a signed appcast from the notarized DMG;
5. creates the GitHub release with `XE-Launcher.dmg` and `appcast.xml`;
6. updates `stable/appcast.xml` or `int/appcast.xml` on the `updates` branch;
7. downloads and validates the newly published feed; and
8. announces the release only after feed validation succeeds.

Stable and prerelease feeds are deliberately separate, so a stable install can
never discover an `int` build. The generated appcast contains only the newest
full DMG for that channel. Delta updates can be added later by retaining prior
archives during appcast generation.

## Verification

Verify a locally assembled application bundle:

```sh
macos/Tests/Integration/verify-sparkle.sh \
  "macos/dist/XE Launcher.app"
```

Pass `--release` to additionally reject the public-key placeholder. The check
validates the framework, helper tools, runtime search path, Info.plist security
settings, and all nested code signatures.

Verify a generated or published appcast:

```sh
macos/Tests/Integration/verify-appcast.sh \
  /path/to/appcast.xml \
  EXPECTED_BUILD_VERSION \
  https://github.com/Agent54/xe-darc-launcher/releases/download/RELEASE/XE-Launcher.dmg
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
