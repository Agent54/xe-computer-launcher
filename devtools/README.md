# Vendored DevTools

DevTools ships locally so browser inspection works offline. Use a prebuilt
frontend archive rather than a Chromium checkout. `DevTools.lock` is the source
of truth for the archive URL and payload fingerprint; its Chromium **major**
must match the shipped Helium in `macos/Sources/macos/Resources/sources.json`.
Patch versions need not match.

## Offline builds

The normal worker build includes DevTools. To supply its input without a
download, use one of:

- The archive at `devtools/devtools-frontend.zip`.
- Its extracted tree under
  `devtools/devtools-frontend/gen/third_party/devtools-frontend/src/front_end/`.
- `DEVTOOLS_SOURCE_DIR` pointing to another extracted `front_end` directory.

For a standalone preview, run `python3 devtools/build.py` from the repo root
and serve `devtools/assets/` over HTTP.

## Maintenance

Keep customization in `theme.css` so upstream updates remain a single
stylesheet replacement rather than a frontend fork. The palette comes from
GitHub Dark Default with Darc's overrides in
`darc-code/vscode-config/settings.json`. DevTools shares one definition token
between function and variable declarations, so those scopes cannot be colored
independently through its theme tokens.

When updating, select an archive that actually exists in the
[public snapshot listing](https://commondatastorage.googleapis.com/chromium-browser-snapshots/index.html),
then update the URL, revision, major and fingerprint together. Chrome patch
versions do not imply publicly accessible release archive URLs. Review the new
resource manifest and theme tokens before accepting a new payload.

Retain the Chromium license and GitHub theme attribution in `LICENSE` and
`theme-source/` when redistributing the frontend.
