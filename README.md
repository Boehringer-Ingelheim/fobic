# FOBIC (Free OBIC)

[![FOBIC Build](https://github.com/Boehringer-Ingelheim/fobic/actions/workflows/build.yml/badge.svg)](https://github.com/Boehringer-Ingelheim/fobic/actions/workflows/build.yml)

FOBIC is a custom [bootc](https://github.com/bootc-dev/bootc) image built on top of [`ghcr.io/ublue-os/aurora-dx`](https://github.com/ublue-os/aurora-dx), customized and published for Boehringer-Ingelheim. It's built with the [Universal Blue](https://universal-blue.org/) image tooling (Containerfile + Just + GitHub Actions).

## Image Streams

The image is published from a single Containerfile across four branches. The base image and the published tag are resolved automatically by CI based on the branch name — the Containerfile itself is identical across branches.

| Branch   | Base image                            | Published tag | Retention        | Purpose                           |
|----------|----------------------------------------|---------------|-------------------|------------------------------------|
| `main`   | `ghcr.io/ublue-os/aurora-dx:latest`   | `testing`     | 1 image           | Integration testing               |
| `latest` | `ghcr.io/ublue-os/aurora-dx:latest`   | `latest`      | 2 images          | Current production (~1 day)    |
| `stable` | `ghcr.io/ublue-os/aurora-dx:stable`   | `stable`      | 2 images          | Conservative production (~weeks)  |
| `feat/*` | `ghcr.io/ublue-os/aurora-dx:latest`   | `feat-{name}` | 1 image           | Feature branch preview            |

Each build also gets dated/SHA tags (e.g. `stable-20260703-a1b2c3d`) for pinning/rollback. Old versions are pruned nightly by [`.github/workflows/cleanup.yml`](.github/workflows/cleanup.yml) according to the retention column above, plus removal of untagged manifests and `feat-*` tags whose branch no longer exists.

## Installing / Switching to FOBIC

From an existing bootc system (Bazzite, Bluefin, Aurora, Fedora Atomic, etc.):

```bash
# Production (recommended for most users)
sudo bootc switch ghcr.io/boehringer-ingelheim/fobic:latest

# Conservative / slower-moving updates
sudo bootc switch ghcr.io/boehringer-ingelheim/fobic:stable

# Pin to a specific dated build for rollback
sudo bootc switch ghcr.io/boehringer-ingelheim/fobic:stable-20260703-a1b2c3d
```

Reboot to complete the switch. All published images are signed with [cosign](https://github.com/sigstore/cosign); the public key is [`cosign.pub`](cosign.pub). See [`docs/image-signing.md`](docs/image-signing.md) for how verification actually works, its guarantees/limits, and incident response for a leaked key.

## How the Build Works

- [`Containerfile`](Containerfile) declares `ARG BASE_IMAGE=ghcr.io/ublue-os/aurora-dx:stable` before the first `FROM`, then does `FROM ${BASE_IMAGE}`. Locally, this default is used when the arg isn't overridden.
- [`.github/workflows/build.yml`](.github/workflows/build.yml) resolves `BASE_IMAGE` and `STREAM_TAG` from the branch name (`resolve-base` / `resolve-stream` steps) and passes them into `just build`, so the same workflow file drives every stream.
- [`.github/renovate.json5`](.github/renovate.json5) tracks `main`, `latest`, and `stable` as base branches and auto-merges `aurora-dx` digest bumps every 6 hours, keeping all streams current with upstream without a nightly rebuild cron.
- Publishing (push/tag/sign) only happens on `push` events (not on pull requests), so PRs build and validate but never publish.

### Branch Promotion

Changes flow forward through the streams via normal merges:

```
feat/my-feature → main (testing) → latest → stable
```

1. Work happens on a `feat/*` branch; pushing it publishes a `feat-{name}` preview image.
2. PR into `main` — CI builds but does not publish. Once merged, `main` publishes `fobic:testing`.
3. Promote `main → latest` (merge/PR) once testing looks good — publishes `fobic:latest`.
4. Promote `latest → stable` (merge/PR, 2 reviewers recommended) once `latest` has proven stable — publishes `fobic:stable`.

Because the workflow file and Containerfile are identical across branches, promoting is just a merge — no manual reconfiguration needed per branch.

## What's Customized

- [`build_files/build.sh`](build_files/build.sh) copies [`system_files/`](system_files) into the image, then runs every numbered script under [`build_files/tasks/`](build_files/tasks) in order (currently: installing Microsoft Edge and OneDrive).
- [`system_files/usr/share/ublue-os/just/`](system_files/usr/share/ublue-os/just) adds extra `just` commands available on the built system: `aws-smp`, `onedrive`, `openshift-client`, and `ssh-key-agent` (see [`60-custom.just`](system_files/usr/share/ublue-os/just/60-custom.just) for the full list).

## Local Development

Requires [`just`](https://just.systems/man/en/introduction.html) and [Podman](https://podman.io/) (both preinstalled on Universal Blue images).

```bash
# Build with the default base image (aurora-dx:stable)
just build

# Build with a specific output tag
just build fobic latest

# Override the base image, e.g. to test against aurora-dx:latest
just build fobic latest ghcr.io/ublue-os/aurora-dx:latest
```

Other useful commands:

```bash
just build-qcow2      # Build a bootable QCOW2 VM image
just build-iso        # Build a bootable ISO
just check            # Validate Justfile/*.just syntax
just clean            # Remove local build artifacts
```

Configuration such as the image name, description, and registry organization lives in [`image-template.env`](image-template.env) and is loaded automatically by `just` — see that file to adjust branding metadata.

## Disk Images (ISO / QCOW2 / RAW)

[`.github/workflows/build-disk.yml`](.github/workflows/build-disk.yml) builds installable disk images from the published `fobic:latest` container using [bootc-image-builder](https://osbuild.org/docs/bootc/), configured via [`disk_config/disk.toml`](disk_config/disk.toml) and [`disk_config/iso.toml`](disk_config/iso.toml). It can optionally upload results to S3 (`upload-to-s3` input) or attach them as a workflow artifact. Trigger it manually from the Actions tab (`workflow_dispatch`).

## Repository Layout

| Path | Purpose |
|---|---|
| [`Containerfile`](Containerfile) | Image build definition; base image injected via `BASE_IMAGE` build-arg |
| [`Justfile`](Justfile) | Build/tag/rechunk/VM commands used locally and in CI |
| [`build_files/`](build_files) | Build entrypoint script and ordered task scripts |
| [`system_files/`](system_files) | Files copied verbatim into the image (etc, usr, just commands) |
| [`disk_config/`](disk_config) | bootc-image-builder configs for VM/ISO output |
| [`.github/workflows/build.yml`](.github/workflows/build.yml) | Builds, tags, signs, and publishes per stream |
| [`.github/workflows/build-disk.yml`](.github/workflows/build-disk.yml) | Builds installable disk images |
| [`.github/workflows/cleanup.yml`](.github/workflows/cleanup.yml) | Prunes old GHCR versions per stream retention policy |
| [`.github/renovate.json5`](.github/renovate.json5) | Automerges base-image digest bumps across streams |
| [`cosign.pub`](cosign.pub) | Public key to verify image signatures |
| [`docs/image-signing.md`](docs/image-signing.md) | How bootc/rpm-ostree signature verification works, FOBIC's setup, and key-compromise incident response |

## Community / Upstream

FOBIC is built on the [Universal Blue](https://universal-blue.org/) project's image template tooling. For general questions about the underlying tooling (not FOBIC-specific), see:

- [Universal Blue Forums](https://universal-blue.discourse.group/)
- [Universal Blue Discord](https://discord.gg/WEu6BdFEtp)
- [bootc discussion forums](https://github.com/bootc-dev/bootc/discussions)
