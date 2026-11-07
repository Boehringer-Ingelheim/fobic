# DINO *(DINO is not OBIC)*

<img src="docs/img/dino.svg" alt="DINO Logo" width="200" align="right"/>

[![DINO Build](https://github.com/boehringer-ingelheim/dino/actions/workflows/build.yml/badge.svg)](https://github.com/boehringer-ingelheim/dino/actions/workflows/build.yml)
[![OSSF-Scorecard Score](https://img.shields.io/ossf-scorecard/github.com/Boehringer-Ingelheim/dino)](https://scorecard.dev/viewer/?uri=github.com%2FBoehringer-Ingelheim%2Fdino)
[![License](https://img.shields.io/github/license/Boehringer-Ingelheim/dino)](LICENSE)

DINO is a custom [bootc](https://github.com/bootc-dev/bootc) image built on top of [`ghcr.io/ublue-os/aurora-dx`](https://github.com/ublue-os/aurora-dx), customized and published for boehringer-ingelheim. It's built with the [Universal Blue](https://universal-blue.org/) image tooling (Containerfile + Just + GitHub Actions).

## Image Streams

The image is published from a single Containerfile across several branch types. Every stream builds on the same digest-pinned `ghcr.io/ublue-os/aurora-dx:stable` base from the Containerfile; CI only derives the published tag from the branch name.

| Branch | Base image | Published tag | Retention | Purpose |
| --- | --- | --- | --- | --- |
| `main` | `ghcr.io/ublue-os/aurora-dx:stable` (pinned) | `latest` | 2 images | Integration testing |
| `stable` | `ghcr.io/ublue-os/aurora-dx:stable` (pinned) | `stable` | 2 images | Production (recommended) |
| `feat/*`, `fix/*` | `ghcr.io/ublue-os/aurora-dx:stable` (pinned) | `feat-{name}`, `fix-{name}` | 1 image | Feature/fix testing |

Each build also gets dated/SHA tags (e.g. `stable-20260703-a1b2c3d`) for pinning/rollback. Old versions are pruned nightly by [`.github/workflows/cleanup.yml`](.github/workflows/cleanup.yml) according to the retention column above, plus removal of untagged manifests and `feat-*`/`fix-*` tags whose branch no longer exists.

## Installing / Switching to DINO

From an existing bootc system (Bazzite, Bluefin, Aurora, Fedora Atomic, etc.):

```bash
# Production (recommended for most users)
sudo bootc switch ghcr.io/boehringer-ingelheim/dino:stable

# Integration testing / newer changes first
sudo bootc switch ghcr.io/boehringer-ingelheim/dino:latest

# Pin to a specific dated build for rollback
sudo bootc switch ghcr.io/boehringer-ingelheim/dino:stable-20260703-a1b2c3d
```

Reboot to complete the switch. All published images are signed with [cosign](https://github.com/sigstore/cosign); the public key is [`cosign.pub`](cosign.pub). See [`docs/image-signing.md`](docs/image-signing.md) for how verification actually works, its guarantees/limits, and incident response for a leaked key.

## How the Build Works

- [`Containerfile`](Containerfile) declares `ARG BASE_IMAGE=ghcr.io/ublue-os/aurora-dx:stable@sha256:…` before the first `FROM`, then does `FROM ${BASE_IMAGE}`. CI and `just build` use this pinned default unless a base image is passed explicitly.
- [`.github/workflows/build.yml`](.github/workflows/build.yml) resolves `STREAM_TAG` from the branch name (`resolve-stream` step) and passes it into `just build`, so the same workflow file drives every stream.
- [`.github/renovate.json5`](.github/renovate.json5) tracks `main` and auto-merges `aurora-dx` digest bumps to the Containerfile every 6 hours; each merge triggers a new build.
- Publishing (push/tag/sign) only happens on `push` events (not on pull requests), so PRs build and validate but never publish.

### Branch Promotion

Changes flow forward through the streams via normal merges:

```text
feat/my-feature (testing) → main (latest) → stable
```

1. Work happens on a `feat/*` or `fix/*` branch; pushing it publishes a corresponding `feat-{name}` or `fix-{name}` testing image.
2. PR into `main` — CI builds but does not publish. Once merged, `main` publishes `dino:latest`.
3. Promote `main → stable` (merge/PR, 2 reviewers recommended) once `latest` has proven stable — publishes `dino:stable`.

Because the workflow file and Containerfile are identical across branches, promoting is just a merge — no manual reconfiguration needed per branch.

## What's Customized

| Area | Configured in | What it includes |
|---|---|---|
| Image build tasks | [`build.sh`](build_files/build.sh), [`tasks/`](build_files/tasks) | Copies [`system_files/`](system_files) into the image, then runs numbered task scripts in order. |
| Image signature trust | [`00-configure-image-signing.sh`](build_files/tasks/00-configure-image-signing.sh), [`container public keys`](system_files/usr/lib/pki/containers) | Adds DINO's signing keys to the container policy so signed DINO images can be verified. |
| Browsers and cloud storage | [`01-install-edge-onedrive.sh`](build_files/tasks/01-install-edge-onedrive.sh), [`02-install-paloalto-browser.sh`](build_files/tasks/02-install-paloalto-browser.sh), [`Prisma Browser RPM repo`](system_files/etc/yum.repos.d/prisma-access-browser.repo) | Installs Microsoft Edge as the default browser, Palo Alto Prisma Access Browser as an alternative, and OneDrive. |
| Display manager | [`98-switch-plasmalogin-for-gdm.sh`](build_files/tasks/98-switch-plasmalogin-for-gdm.sh) | Replaces Plasma Login with GDM. |
| Entra ID sign-in | [`99-install-himmelblau.sh`](build_files/tasks/99-install-himmelblau.sh), [`himmelblau-brew-ownership`](system_files/usr/libexec/himmelblau/logon.d/himmelblau-brew-ownership) | Installs and configures Himmelblau; on first login, assigns `/home/linuxbrew` to the authenticated user's runtime UID/GID. |
| Extra `just` commands | [`60-custom.just`](system_files/usr/share/ublue-os/just/60-custom.just) | Imports optional recipes for `aws-smp`, `onedrive`, `openshift-client`, and `ssh-key-agent`. |

## Local Development

Requires [`just`](https://just.systems/man/en/introduction.html) and [Podman](https://podman.io/) (both preinstalled on Universal Blue images).

```bash
# Build with the digest-pinned default base image from the Containerfile
just build

# Build with a specific output tag
just build dino latest

# Override the base image, e.g. to test against aurora-dx:latest
just build dino latest ghcr.io/ublue-os/aurora-dx:latest
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

[`.github/workflows/build-disk.yml`](.github/workflows/build-disk.yml) builds installable disk images from the published `dino:latest` container using [bootc-image-builder](https://osbuild.org/docs/bootc/), configured via [`disk_config/disk.toml`](disk_config/disk.toml) and [`disk_config/iso.toml`](disk_config/iso.toml). It can optionally upload results to S3 (`upload-to-s3` input) or attach them as a workflow artifact. Trigger it manually from the Actions tab (`workflow_dispatch`).

See [Building and testing an installer ISO locally](docs/local-installer-testing.md) for the complete GitHub Actions, download, and Fedora/QEMU workflow.

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
| [`docs/image-signing.md`](docs/image-signing.md) | How bootc/rpm-ostree signature verification works, DINO's setup, and key-compromise incident response |

## Community / Upstream

DINO is built on the [Universal Blue](https://universal-blue.org/) project's image template tooling. For general questions about the underlying tooling (not DINO-specific), see:

- [Universal Blue Forums](https://universal-blue.discourse.group/)
- [Universal Blue Discord](https://discord.gg/WEu6BdFEtp)
- [bootc discussion forums](https://github.com/bootc-dev/bootc/discussions)
