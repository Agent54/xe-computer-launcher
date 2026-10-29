# Local release secrets

`sparkle-private-key` is the exported Sparkle Ed25519 private signing key. It is
ignored by Git and must never be committed, pasted into logs, or shared as a
public GitHub Actions variable. Store its value in the GitHub Actions secret
named `SPARKLE_PRIVATE_KEY` and retain an encrypted backup outside this
checkout.

The matching public key is public, but release builds expect it in the Actions
secret `SPARKLE_PUBLIC_ED_KEY`. Retrieve it separately from the `macos` directory:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account dev.xe.computer \
  -p
```
