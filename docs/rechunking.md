# Image Rechunking (Chunkah)

This document explains why OCI container images built for `bootc` / `rpm-ostree`
are rechunked after `podman build`, how [Chunkah](https://github.com/coreos/chunkah)
works in FOBIC and upstream `ublue-os/aurora`, and how to run or customize
rechunking locally.

## 1. Why rechunking is needed

A standard `podman build` executes [`build_files/build.sh`](../build_files/build.sh)
in a single `RUN` instruction. Without post-processing, every file added or
modified by FOBIC (such as Microsoft Edge, Himmelblau, AWS CLI, OpenShift CLI,
and `/etc` configuration) lands in **one large, monolithic OCI layer** on top of
the base image:

- **Poor update granularity:** If a future build only changes a small script or
  updates a single package (e.g. `onedrive`), clients running `bootc upgrade`
  would otherwise have to re-download the entire customization layer (including
  hundreds of megabytes of unchanged packages like `microsoft-edge-stable` and
  `gdm`).
- **Download resumability:** Splitting the image into smaller, deterministic
  layers (up to 256 layers) allows `bootc` / `ostree-ext` to fetch and resume
  individual layers and skip any layers whose digest has not changed since the
  currently deployed image.

## 2. Chunkah vs. `rpm-ostree compose build-chunked-oci`

Universal Blue and Fedora Atomic images have historically used two rechunkers:

| Tool | `Justfile` recipe | How it works |
|---|---|---|
| **[Chunkah](https://github.com/coreos/chunkah)** (Active) | `just rechunk` | Distro-agnostic OCI rechunker (`quay.io/coreos/chunkah`). Inspects the RPM database and `user.component` extended attributes (`xattrs`) inside the image, then repacks the filesystem into up to 256 compressed OCI layers without requiring a privileged `rpm-ostree` container. |
| **`rpm-ostree`** (Legacy fallback) | `just ostree-rechunk` | Runs `rpm-ostree compose build-chunked-oci` inside a privileged container with host container storage bind-mounted. Limited to 127 layers and tightly coupled to `rpm-ostree` internals. |

### Why FOBIC uses Chunkah

Upstream [`ublue-os/aurora`](https://github.com/ublue-os/aurora) migrated from
`rpm-ostree` to **Chunkah** (`--max-layers 256`). Because FOBIC derives from
`ghcr.io/ublue-os/aurora-dx`, rechunking FOBIC with Chunkah ensures that
unchanged base packages are packed using the same component-grouping logic and
maximum layer budget (`256`) as upstream `aurora-dx`.

## 3. How FOBIC prepares the image for Chunkah

At the end of [`build_files/build.sh`](../build_files/build.sh), FOBIC performs
four preparation steps before the container layer is committed (mirroring
`ublue-os/aurora`'s `clean-stage.sh` and `unpackaged.sh`):

1. **Clear `libdnf5` transaction state (`rm -rf /usr/lib/sysimage/libdnf5/*`):**
   `dnf5` writes transaction history and state into `/usr/lib/sysimage/libdnf5`.
   Leaving those files in place causes Chunkah to see modified files in the
   `libdnf5` package component and invalidates that layer on every build.
2. **Hardlink `rpmdb.sqlite*` into `/usr/lib/sysimage/rpm-ostree-base-db/`:**
   When `dnf5` installs packages during the container build, it rewrites
   `/usr/share/rpm/rpmdb.sqlite`, breaking the hardlink to
   `/usr/lib/sysimage/rpm-ostree-base-db/rpmdb.sqlite` inherited from the base
   image. Re-creating the hardlink (`ln -f`) ensures both `rpm-ostree`/`bootc`
   and Chunkah read the up-to-date RPM database and avoids duplicating the
   ~155 MiB SQLite database in the image.
3. **Tag unpackaged files with `user.component` extended attributes:**
   Files installed via `dnf5` (like `microsoft-edge-stable`, `onedrive`,
   `awscli2`, `gdm`, and `himmelblau`) are automatically grouped by Chunkah
   using the RPM database. For files copied from [`system_files/`](../system_files)
   or installed directly from upstream archives, `build.sh` sets
   `user.component` extended attributes (`setfattr -n user.component -v ...`)
   so Chunkah groups them into dedicated, cacheable component layers:
   - `aws-session-manager-plugin`: `/usr/bin/session-manager-plugin`
   - `openshift-client`: `/usr/bin/oc`, `/usr/bin/kubectl`
   - `fobic-config`: Himmelblau logon/boot helpers, container signing public
     keys, and Boehringer Ingelheim CA trust anchors/bundles
4. **Normalize file timestamps (`1970-01-01T00:00:01Z`):**
   Rebuilding an image at a later time normally updates file `mtime` values,
   which changes tar layer hashes even when file contents are identical.
   [`build_files/build.sh`](../build_files/build.sh) normalizes modification
   times across `/usr`, `/etc`, and `/opt` to `1970-01-01T00:00:01Z` so
   unchanged components produce identical layer digests across rebuilds.

## 4. How `just rechunk` works in CI and locally

In [`Justfile`](../Justfile) and [`.github/workflows/build.yml`](../.github/workflows/build.yml),
rechunking runs immediately after `just build`:

```bash
# 1. Build the image from Containerfile
just build fobic latest

# 2. Rechunk the built image with Chunkah
just rechunk fobic latest
```

Under the hood, `just rechunk`:

1. Exports the built image's OCI metadata (`podman inspect fobic:latest`) to a
   temporary JSON file (`CHUNKAH_CONFIG_FILE`).
2. Mounts the built image (`--mount=type=image,src=fobic:latest,target=/chunkah`),
   the config file (`/chunkah-config.json`), and a temporary output directory
   (`/run/out`) into `quay.io/coreos/chunkah:latest`.
3. Runs `chunkah build --compressed --max-layers 256 --prune /sysroot/ --label ostree.commit- --label ostree.final-diffid- --config /chunkah-config.json --output oci:/run/out/chunked`.
4. Pulls the resulting chunked OCI layout back into local Podman storage
   (`podman pull oci:...`) and tags it as `fobic:latest`, replacing the
   un-chunked build output before tags are generated, pushed, and signed.

> **Note on rootless vs. rootful Podman:** `just rechunk` works in rootless
> Podman when the image was built rootless (`just build ... && just rechunk ...`).
> If the image was built in rootful Podman storage (`sudo just build ...`, as
> done in [`.github/workflows/build.yml`](../.github/workflows/build.yml)), run
> `sudo just rechunk ...` so Chunkah reads and writes the same container storage.
