# Building and testing an installer ISO locally

This guide builds the installer from the latest `main` image with GitHub Actions,
downloads it, and tests an installation in a local QEMU/KVM virtual machine on
Fedora.

## Prerequisites

Install the required tools:

```bash
sudo dnf install gh qemu-img qemu-system-x86-core qemu-ui-gtk edk2-ovmf swtpm
```

Authenticate the GitHub CLI and check that KVM is available:

```bash
gh auth status
test -r /dev/kvm && test -w /dev/kvm && echo "KVM access is ready"
```

QEMU should run as the normal user, not with `sudo`.

## Build the ISO with GitHub Actions

Make sure local `main` matches the latest remote commit:

```bash
git fetch origin main
git rev-list --left-right --count main...origin/main
```

The expected result is `0  0`. Trigger the amd64 disk-image workflow:

```bash
gh workflow run build-disk.yml \
  --repo Boehringer-Ingelheim/fobic \
  --ref main \
  -f platform=amd64 \
  -f upload-to-s3=false
```

Find the newly dispatched run and wait for it:

```bash
RUN_ID="$(
  gh run list \
    --repo Boehringer-Ingelheim/fobic \
    --workflow build-disk.yml \
    --event workflow_dispatch \
    --limit 1 \
    --json databaseId \
    --jq '.[0].databaseId'
)"

gh run watch "$RUN_ID" \
  --repo Boehringer-Ingelheim/fobic \
  --exit-status \
  --interval 30
```

### Preserve the ISO artifact

The workflow currently builds both QCOW2 and Anaconda ISO matrix jobs. Both jobs
upload an artifact named `artifact` with `overwrite: true`, so whichever job
uploads last replaces the other artifact.

After the first run finishes, find the Anaconda ISO job ID:

```bash
ISO_JOB_ID="$(
  gh run view "$RUN_ID" \
    --repo Boehringer-Ingelheim/fobic \
    --json jobs \
    --jq '.jobs[] | select(.name | contains("anaconda-iso")) | .databaseId'
)"
```

Rerun only that job so the surviving artifact is the ISO:

```bash
gh run rerun "$RUN_ID" \
  --repo Boehringer-Ingelheim/fobic \
  --job "$ISO_JOB_ID"

gh run watch "$RUN_ID" \
  --repo Boehringer-Ingelheim/fobic \
  --exit-status \
  --interval 30
```

## Download the ISO

```bash
mkdir -p output/main-iso

gh run download "$RUN_ID" \
  --repo Boehringer-Ingelheim/fobic \
  --name artifact \
  --dir output/main-iso

ISO="$(find "$PWD/output/main-iso" -type f -name '*.iso' -print -quit)"
test -n "$ISO" || { echo "ISO not found"; exit 1; }
ISO="$(realpath "$ISO")"
echo "$ISO"
```

The Actions artifact is several gigabytes, so the download can take some time.

## Prepare the VM

Create a 64 GiB sparse QCOW2 disk, a writable copy of the UEFI variable store,
and persistent TPM state:

```bash
mkdir -p "$HOME/vm-disks/fobic-test"
mkdir -p "$HOME/vm-disks/fobic-test/tpm"

qemu-img create \
  -f qcow2 \
  "$HOME/vm-disks/fobic-test/system.qcow2" \
  64G

cp /usr/share/edk2/ovmf/OVMF_VARS.fd \
  "$HOME/vm-disks/fobic-test/OVMF_VARS.fd"
```

FOBIC configures Himmelblau with `hsm_type = tpm`, so the VM must have a TPM
2.0 device. Start the software TPM before each QEMU launch:

```bash
rm -f "$HOME/vm-disks/fobic-test/tpm/swtpm.sock"

swtpm socket \
  --tpm2 \
  --tpmstate dir="$HOME/vm-disks/fobic-test/tpm" \
  --ctrl type=unixio,path="$HOME/vm-disks/fobic-test/tpm/swtpm.sock" \
  --terminate \
  --daemon
```

## Run the installer

Run this from the same shell in which `ISO` was set:

```bash
qemu-system-x86_64 \
  -name fobic-installer \
  -machine q35,accel=kvm \
  -cpu host \
  -smp 8 \
  -m 8192 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
  -drive if=pflash,format=raw,file="$HOME/vm-disks/fobic-test/OVMF_VARS.fd" \
  -drive file="$HOME/vm-disks/fobic-test/system.qcow2",if=virtio,format=qcow2,cache=none,discard=unmap \
  -drive file="$ISO",media=cdrom,readonly=on \
  -chardev socket,id=chrtpm,path="$HOME/vm-disks/fobic-test/tpm/swtpm.sock" \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-crb,tpmdev=tpm0 \
  -boot once=d,menu=on \
  -device virtio-vga \
  -display gtk \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -usb \
  -device usb-tablet
```

`-boot once=d` boots the installer ISO first and prefers the installed disk
after reboot. Press `Ctrl+Alt+G` to release the mouse pointer.

## Boot the installed system

If the VM returns to the installer, close it and restart without attaching the
ISO. Start `swtpm` again first because `--terminate` stops it when QEMU exits:

```bash
rm -f "$HOME/vm-disks/fobic-test/tpm/swtpm.sock"

swtpm socket \
  --tpm2 \
  --tpmstate dir="$HOME/vm-disks/fobic-test/tpm" \
  --ctrl type=unixio,path="$HOME/vm-disks/fobic-test/tpm/swtpm.sock" \
  --terminate \
  --daemon
```

Then boot the installed disk:

```bash
qemu-system-x86_64 \
  -name fobic-installed \
  -machine q35,accel=kvm \
  -cpu host \
  -smp 8 \
  -m 8192 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
  -drive if=pflash,format=raw,file="$HOME/vm-disks/fobic-test/OVMF_VARS.fd" \
  -drive file="$HOME/vm-disks/fobic-test/system.qcow2",if=virtio,format=qcow2,cache=none,discard=unmap \
  -chardev socket,id=chrtpm,path="$HOME/vm-disks/fobic-test/tpm/swtpm.sock" \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-crb,tpmdev=tpm0 \
  -device virtio-vga \
  -display gtk \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -usb \
  -device usb-tablet
```

The network configuration provides outbound connectivity and forwards host TCP
port `2222` to guest SSH port `22` if SSH is enabled. The installer locks the
root account and does not create a conventional local user; the installed
system is intended to authenticate through Himmelblau.

If GDM reports `Himmelblau authentication service did not become available in
time`, first confirm that the VM was started with the TPM arguments above. The
image requires a TPM and does not fall back to software key storage. From a
guest console with administrative access, inspect the failure with:

```bash
systemctl status himmelblau-hsm-pin-init himmelblaud himmelblaud-tasks
journalctl -b -u himmelblau-hsm-pin-init -u himmelblaud -u himmelblaud-tasks
ls -l /dev/tpm*
```

To repeat the installation from a blank disk:

```bash
rm "$HOME/vm-disks/fobic-test/system.qcow2"
rm -rf "$HOME/vm-disks/fobic-test/tpm"
mkdir -p "$HOME/vm-disks/fobic-test/tpm"
qemu-img create -f qcow2 "$HOME/vm-disks/fobic-test/system.qcow2" 64G
```
