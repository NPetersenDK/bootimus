#!/bin/bash
set -euo pipefail

# Builds the "secureboot-official" bootloader set — the zero-enrollment
# UEFI Secure Boot chain:
#   - Microsoft-signed shim + MokManager from the ipxe/shim release
#   - Stock iPXE binaries signed by the iPXE project's own Secure Boot CA,
#     taken from the official iPXE release (v2.0+)
#   - Official wimboot release binary for Windows images
#
# Nothing is signed locally and no per-machine cert enrollment is needed:
# firmware trusts the Microsoft-signed shim, shim trusts the iPXE Secure Boot
# CA baked into it as vendor certificate.
#
# Tradeoffs vs the "secureboot" set (scripts/build-secureboot-set.sh):
#   - The official iPXE binaries do NOT contain the Bootimus embed.ipxe script.
#     Discovery relies on iPXE (>= v2.0) automatically fetching autoexec.ipxe
#     over TFTP, which Bootimus generates dynamically per client.
#   - iPXE v2.0.0 has a known keyboard regression in interactive menus (the
#     reason the self-built sets pin v1.21.1). Test menu input on real
#     hardware; prefer the newest v2.0.x point release via IPXE_VERSION.
#   - NBD/NFS image boots still fail under Secure Boot: the Bootimus boot
#     environment kernel is unsigned and no public CA will sign it. Those
#     methods need the "secureboot" set + cert enrollment, or Secure Boot off.
#
# Requirements on the host: curl, tar

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTLOADERS_DEFAULT="$ROOT_DIR/bootloaders/default"
OUT_DIR="$ROOT_DIR/bootloaders/secureboot-official"

SHIM_VERSION="${SHIM_VERSION:-16.1}"
# ipxe/shim release tags are prefixed with "ipxe-" (e.g. ipxe-16.1).
SHIM_RELEASE_BASE="https://github.com/ipxe/shim/releases/download/ipxe-${SHIM_VERSION}"
# First iPXE release with official Secure Boot signed binaries is v2.0.0.
IPXE_VERSION="${IPXE_VERSION:-v2.0.0}"
IPXE_RELEASE_BASE="https://github.com/ipxe/ipxe/releases/download/${IPXE_VERSION}"
WIMBOOT_VERSION="${WIMBOOT_VERSION:-v2.9.0}"
WIMBOOT_RELEASE_BASE="https://github.com/ipxe/wimboot/releases/download/${WIMBOOT_VERSION}"

for tool in curl tar; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Required tool not found in PATH: $tool" >&2
        exit 1
    fi
done

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

# --- download Microsoft-signed shim + MokManager ------------------------------

echo "==> Downloading ipxe/shim ${SHIM_VERSION} signed binaries"
curl -fsSL -o "$STAGING/ipxe-shimx64.efi"  "$SHIM_RELEASE_BASE/ipxe-shimx64.efi"
curl -fsSL -o "$STAGING/ipxe-shimaa64.efi" "$SHIM_RELEASE_BASE/ipxe-shimaa64.efi"
curl -fsSL -o "$STAGING/mmx64.efi"         "$SHIM_RELEASE_BASE/mmx64.efi"
curl -fsSL -o "$STAGING/mmaa64.efi"        "$SHIM_RELEASE_BASE/mmaa64.efi"

# --- download official signed iPXE binaries -----------------------------------

echo "==> Downloading iPXE ${IPXE_VERSION} signed netboot archive"
curl -fsSL -o "$STAGING/ipxeboot.tar.gz" "$IPXE_RELEASE_BASE/ipxeboot.tar.gz"
mkdir -p "$STAGING/extract"
tar -xzf "$STAGING/ipxeboot.tar.gz" -C "$STAGING/extract"

# The archive layout is not guaranteed across releases; locate binaries by
# name and fail loudly with a listing if the expected names are missing.
locate_one() {
    local pattern="$1"
    local match
    match="$(find "$STAGING/extract" -type f -name "$pattern" | head -n1)"
    if [[ -z "$match" ]]; then
        echo "Could not find $pattern inside ipxeboot.tar.gz — archive layout changed?" >&2
        echo "Archive contents:" >&2
        find "$STAGING/extract" -type f >&2
        exit 1
    fi
    printf '%s\n' "$match"
}

# shim derives the second-stage name from its own filename:
# ipxe-shimx64.efi loads ipxe.efi, so the signed binary must keep that name.
X64_IPXE="$(find "$STAGING/extract" -type f \( -path '*x86_64*' -o -path '*x64*' \) -name 'ipxe.efi' | head -n1)"
if [[ -z "$X64_IPXE" ]]; then
    X64_IPXE="$(locate_one 'ipxe.efi')"
fi
cp "$X64_IPXE" "$STAGING/ipxe.efi"

ARM64_IPXE="$(find "$STAGING/extract" -type f \( -path '*arm64*' -o -path '*aa64*' \) -name '*.efi' \( -name 'ipxe*' -o -name 'snponly*' \) | head -n1)"
if [[ -n "$ARM64_IPXE" ]]; then
    cp "$ARM64_IPXE" "$STAGING/ipxe-arm64.efi"
else
    echo "WARNING: no ARM64 iPXE binary found in the archive; skipping ARM64 support" >&2
fi

# --- download official wimboot -------------------------------------------------

echo "==> Downloading wimboot ${WIMBOOT_VERSION}"
curl -fsSL -o "$STAGING/wimboot" "$WIMBOOT_RELEASE_BASE/wimboot"

# --- assemble the output set ---------------------------------------------------

echo "==> Assembling $OUT_DIR"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

cp "$STAGING/ipxe-shimx64.efi"  "$OUT_DIR/"
cp "$STAGING/ipxe-shimaa64.efi" "$OUT_DIR/"
cp "$STAGING/mmx64.efi"         "$OUT_DIR/"
cp "$STAGING/mmaa64.efi"        "$OUT_DIR/"
cp "$STAGING/ipxe.efi"          "$OUT_DIR/"
if [[ -f "$STAGING/ipxe-arm64.efi" ]]; then
    cp "$STAGING/ipxe-arm64.efi" "$OUT_DIR/"
fi
cp "$STAGING/wimboot"           "$OUT_DIR/"
# BIOS clients don't do Secure Boot; reuse the stock undionly.kpxe.
cp "$BOOTLOADERS_DEFAULT/undionly.kpxe" "$OUT_DIR/"

cat > "$OUT_DIR/manifest.json" <<EOF
{
  "name": "secureboot-official",
  "description": "Zero-enrollment UEFI Secure Boot: Microsoft-signed shim ${SHIM_VERSION} + official iPXE ${IPXE_VERSION} binaries signed by the iPXE Secure Boot CA. No embedded script — relies on autoexec.ipxe over TFTP (iPXE >= 2.0).",
  "shim_version": "${SHIM_VERSION}",
  "bootfiles": {
    "bios": "undionly.kpxe",
    "uefi": "ipxe-shimx64.efi",
    "arm64": "ipxe-shimaa64.efi"
  }
}
EOF

echo
echo "Done. Zero-enrollment secureboot set in $OUT_DIR:"
ls -lh "$OUT_DIR"
echo
echo "Verify signatures before deploying (sbsigntool provides sbverify):"
echo "  sbverify --list $OUT_DIR/ipxe-shimx64.efi   # expect Microsoft UEFI CA"
echo "  sbverify --list $OUT_DIR/ipxe.efi           # expect iPXE Secure Boot CA"
echo "  sbverify --list $OUT_DIR/wimboot            # check before relying on Windows boots"
echo
echo "This set is not embedded in the bootimus binary (its binaries are not"
echo "committed). Copy it into the data directory as an on-disk set:"
echo "  cp -r $OUT_DIR <data_dir>/bootloaders/secureboot-official"
echo "then select it via the bootloader-sets API/UI. The built-in proxyDHCP"
echo "advertises the manifest's bootfiles automatically. External DHCP servers"
echo "must point UEFI clients at ipxe-shimx64.efi themselves."
