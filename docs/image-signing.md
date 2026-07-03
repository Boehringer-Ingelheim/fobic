# Image Signing & Verification

This document describes how container image signature verification works on
bootc/rpm-ostree systems in general, exactly how FOBIC is set up, and the
incident response process for a leaked signing key.

## 1. How bootc and rpm-ostree handle signatures

### They share the same code

`bootc` and `rpm-ostree` both build on the same underlying Rust crate
(`ostree-rs-ext` / `ostree-ext`) for fetching OCI container images and
deploying them as ostree commits. For container image sources, `rpm-ostree
upgrade`/`rebase` and `bootc upgrade`/`switch` are effectively equivalent —
they use the same fetch and verification code path.

### Verification is delegated to `containers-policy.json`

Neither tool has its own signature-verification logic. Both defer to the
standard `containers/image` library (the same library `podman` and `skopeo`
use), which reads:

- `/etc/containers/policy.json` — defines, per registry/repository scope,
  what (if anything) is required to trust an image.
- `/etc/containers/registries.d/*.yaml` — tells the library *where* to look
  up a signature for a given registry (e.g. as a sigstore/OCI attachment vs.
  a "simple signing" lookaside URL).

A `policy.json` scope entry has a `type`, most relevantly:

- `insecureAcceptAnything` — no verification, anything is accepted. This is
  effectively podman/skopeo's default for any registry not explicitly listed.
- `reject` — nothing from this scope is ever accepted.
- `signedBy` — requires a classic GPG signature.
- `sigstoreSigned` — requires a valid [sigstore/cosign](https://github.com/sigstore/cosign)
  signature matching one of the given public keys (`keyPath`/`keyPaths`).

### `rpm-ostree`'s transport prefixes

`rpm-ostree rebase`/`upgrade` additionally accept explicit transport prefixes:

| Prefix | Behavior |
|---|---|
| `ostree-unverified-registry:` | Fetch with **no** verification, unconditionally — bypasses `policy.json` entirely by design. |
| `ostree-image-signed:` | Fetch and **defer to whatever `policy.json` says** for that reference. |
| `ostree-remote-image:`/`ostree-remote-registry:` | Verify the *ostree commit* is GPG-signed per an ostree remote config — a different, older mechanism, unrelated to sigstore/cosign. |

Important nuance: `ostree-image-signed:` does **not** mean "a signature is
always required." It means "ask `policy.json`." If `policy.json`'s answer for
that scope is `insecureAcceptAnything` (true for any repository not
explicitly listed), then `ostree-image-signed:` succeeds with **no signature
check at all** — this is expected, documented behavior, not a bug.

### `bootc`'s equivalent

`bootc switch`/`upgrade` has no transport-prefix scheme. It always defers to
`policy.json`, i.e. it always behaves like `ostree-image-signed:`. The
`--enforce-container-sigpolicy` flag exists specifically to make `bootc`
**refuse** to proceed if the resolved policy for the target image is
`insecureAcceptAnything`, instead of silently accepting it.

### What this guarantees — and what it does not

Guarantees, once a repository has a `sigstoreSigned` scope configured locally:

- The registry/network path cannot substitute a different or tampered image
  without also forging a valid signature for a trusted key.
- A compromised registry push credential (without the signing key) cannot
  push a trusted-looking update.
- Failures are closed: if verification fails, the upgrade/switch is aborted
  and the machine stays on its current, already-verified deployment.

Does **not** guarantee:

- Protection if the **signing private key itself** is compromised — whoever
  holds it can sign anything and pass verification. Signing proves
  *provenance* ("built and signed by holder of this key"), not *safety* of
  the content.
- Protection against a compromised **build pipeline** producing legitimately
  signed but malicious content.
- Anything about **Secure Boot or TPM**. Those operate at the
  firmware/bootloader/kernel layer (verifying the boot chain before Linux
  userspace starts). `policy.json`/sigstore verification is a separate,
  userspace/network-layer check performed at container image pull time. They
  are complementary but entirely independent security layers; FOBIC and its
  aurora-dx base use neither the experimental composefs/UKI "sealed image"
  model nor any custom Secure Boot key enrollment — only the standard ostree
  backend with the base OS's own Secure Boot chain (unrelated to FOBIC's
  cosign key).
- Verification of the **very first** switch to a new image family. A machine
  not yet running FOBIC has no FOBIC-specific `policy.json` scope yet, so
  that first pull falls through to `insecureAcceptAnything` regardless of
  which tool or prefix is used (see [§3](#3-known-bootstrap-gap-first-switch-to-fobic)).

## 2. FOBIC's concrete setup

### Signing (CI)

[`.github/workflows/build.yml`](../.github/workflows/build.yml) signs every
published image with cosign, using a repository secret:

```yaml
- name: Sign container image
  env:
    COSIGN_PRIVATE_KEY: ${{ secrets.SIGNING_SECRET }}
    DIGEST: ${{ steps.push-image.outputs.digest }}
  run: |
    cosign sign -y --key env://COSIGN_PRIVATE_KEY ${IMAGE_REGISTRY}/${IMAGE_NAME}@${DIGEST}
```

This is classic cosign key-pair signing (`cosign generate-key-pair`), not
keyless/Fulcio signing. The public half is committed at
[`cosign.pub`](../cosign.pub) for manual verification:

```bash
cosign verify --key cosign.pub ghcr.io/boehringer-ingelheim/fobic:latest
```

### Client-side trust (baked into the image)

Signing alone does not make `bootc switch`/`upgrade` or `rpm-ostree
rebase`/`upgrade` verify anything — the client's `policy.json` must also be
configured to require it (see [§1](#1-how-bootc-and-rpm-ostree-handle-signatures)).
FOBIC bakes this in so that, once a machine is running FOBIC, every
subsequent update is checked automatically:

- [`build_files/tasks/00-configure-image-signing.sh`](../build_files/tasks/00-configure-image-signing.sh)
  runs at build time and merges a `sigstoreSigned` scope for
  `ghcr.io/boehringer-ingelheim/fobic` into `/etc/containers/policy.json`,
  using `jq`. It merges rather than overwrites the file, because the aurora-dx
  base image already ships its own `policy.json` (with `ghcr.io/ublue-os`,
  Red Hat, and toolbx-images scopes) — a static file drop would silently
  clobber that and go stale on every upstream update.
- [`system_files/usr/lib/pki/containers/fobic.pub`](../system_files/usr/lib/pki/containers/fobic.pub)
  and [`fobic-backup.pub`](../system_files/usr/lib/pki/containers/fobic-backup.pub)
  are the two trusted public keys (see [§4](#4-incident-response-leaked-signing-key)
  for why there are two).
- [`system_files/etc/containers/registries.d/fobic.yaml`](../system_files/etc/containers/registries.d/fobic.yaml)
  tells `containers/image` to look up FOBIC's signature as a sigstore OCI
  attachment (`use-sigstore-attachments: true`), mirroring how
  `registries.d/ublue-os.yaml` is configured for `ghcr.io/ublue-os`.

The resulting merged policy entry:

```json
"ghcr.io/boehringer-ingelheim/fobic": [
  {
    "type": "sigstoreSigned",
    "keyPaths": [
      "/usr/lib/pki/containers/fobic.pub",
      "/usr/lib/pki/containers/fobic-backup.pub"
    ],
    "signedIdentity": { "type": "matchRepository" }
  }
]
```

Because `/etc` on ostree/bootc systems persists and is 3-way merged across
updates, once a machine has booted a FOBIC deployment with this policy
present, it stays present (and gets updated) on every subsequent update,
independent of whether the admin used `bootc` or `rpm-ostree`.

## 3. Known bootstrap gap: first switch to FOBIC

A machine switching from Aurora (or any other base) to FOBIC for the very
first time is still running the *previous* image's `policy.json`, which has
no FOBIC-specific scope. That first pull therefore falls through to the
`docker` transport's `insecureAcceptAnything` catch-all and succeeds without
any signature check — this is unavoidable from the image side, since the
trust configuration only exists inside the FOBIC image itself, which hasn't
been fetched yet.

From the second update onward (once the machine is running FOBIC and has
adopted its `policy.json`), every `bootc upgrade`/`switch` and `rpm-ostree
upgrade`/`rebase` to `ghcr.io/boehringer-ingelheim/fobic` is verified.

Administrators who want the first switch itself verified can manually
pre-stage the same `policy.json`/`registries.d` snippet on the source system
before switching, or use `bootc switch --enforce-container-sigpolicy` /
`rpm-ostree rebase ostree-image-signed:...` and expect it to fail closed
until that pre-staging is done (rather than silently succeed).

## 4. Incident response: leaked signing key

### Why there are two keys

`fobic.pub` is the active key (its private half, `SIGNING_SECRET`, is used by
CI today). `fobic-backup.pub`'s private half is generated up front and kept
**offline** (e.g. in the org's password manager), never used for day-to-day
signing. Both public keys are baked into every FOBIC image from day one via
`keyPaths` (verification succeeds if a signature matches *either* key).

This exists specifically to avoid a lockout: if we only shipped one key and
had to rotate it after a compromise, the very update that ships the new key
would itself need to be signed with a key nothing yet trusts — a
chicken-and-egg problem. Pre-provisioning a second, already-trusted key
avoids that.

### If the primary private key (`SIGNING_SECRET`) is compromised

1. **Stop using the compromised key immediately.** Replace the
   `SIGNING_SECRET` GitHub Actions repository secret with the (previously
   offline) backup private key. No image or client change is needed for this
   step — every machine already trusts `fobic-backup.pub`, so builds signed
   with it verify successfully on existing deployments right away.
2. **Revoke the compromised key.** Ensure the old private key material is
   deleted everywhere it was stored (password manager entry, any local
   copies, CI secret history if retrievable). Treat it as permanently burned;
   never reuse it.
3. **Audit for misuse before detection.** Check GHCR for any image versions
   pushed/signed in the suspected compromise window that weren't produced by
   a legitimate CI run. Cross-reference `.github/workflows/build.yml` run
   history (commit SHAs, timestamps, actors) against what's actually in the
   registry.
4. **Ship a rotation build.** Generate a *new* backup keypair
   (`cosign generate-key-pair`, keep the private half offline as before).
   Update [`00-configure-image-signing.sh`](../build_files/tasks/00-configure-image-signing.sh)'s
   `keyPaths` to `[fobic.pub (new active key, formerly the backup), new-fobic-backup.pub]`,
   and replace the `fobic.pub`/`fobic-backup.pub` files under
   `system_files/usr/lib/pki/containers/` accordingly. Also update the
   root [`cosign.pub`](../cosign.pub) used for manual verification.
5. **Wait for fleet propagation before fully retiring the compromised key.**
   Don't remove the compromised key from `keyPaths` until you're confident
   affected machines have picked up at least one update carrying the
   rotated policy — otherwise a machine that hasn't updated yet could
   momentarily lose trust in the (still valid, not-yet-rotated) key it's
   currently relying on. Given this project's retention windows (`latest`
   keeps ~8 builds/~days, `stable` ~4/~weeks — see
   [`.github/workflows/cleanup.yml`](../.github/workflows/cleanup.yml)),
   a couple of promotion cycles is generally sufficient.
6. **Remediate already-affected machines, if applicable.** Client-side
   verification only prevents *future* acceptance of images signed with the
   compromised key — it cannot retroactively undo an update that was already
   staged/booted before the compromise was discovered. If step 3's audit
   finds a malicious image was pulled by any machine, remediate it directly
   (`bootc rollback`, or a forced re-provision), rather than relying on the
   signing policy to fix it after the fact.

### Storage guidance

Keep the backup private key **offline** during normal operation (a
password manager / secrets vault entry, not a live GitHub Actions secret).
Only import it into `SIGNING_SECRET` at the moment of an actual rotation.
This avoids a single GitHub-account-level compromise exposing both the
active and backup keys simultaneously.
