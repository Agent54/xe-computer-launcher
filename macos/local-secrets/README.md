# Local release secrets

This visible directory holds release secrets used from this local checkout.

`sparkle-private-key` is the exported Sparkle Ed25519 private signing key. It is
ignored by Git and must never be committed, pasted into logs, or shared as a
public GitHub Actions variable. Store its value in the GitHub Actions secret
named `SPARKLE_PRIVATE_KEY` and retain an encrypted backup outside this
checkout.

The matching public key is not cryptographically secret, but this repository
reads it from the GitHub Actions secret named `SPARKLE_PUBLIC_ED_KEY`; release
builds embed it for update verification. Print it separately from the `macos`
directory with:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account dev.xe.computer \
  -p
```
