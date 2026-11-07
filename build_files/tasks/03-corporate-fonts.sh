#!/bin/bash

set -Eeuox pipefail

# Always install under /usr: on bootc images /usr/local links to /var/usrlocal,
# and /var is only seeded on first install, so fonts there would never update.
OUTPUT_DIR="/usr/share/fonts/boehringer-forward"

require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "Missing required dependency: $1" >&2
		exit 1
	fi
}

# Map font weight/style pairs to the subfamily names expected by desktop apps.
subfamily_name() {
	local weight="$1"
	local style="${2:-normal}"
	case "${weight}|${style}" in
	"400|normal") echo "Regular" ;;
	"400|italic") echo "Italic" ;;
	"500|normal") echo "Medium" ;;
	"500|italic") echo "Medium Italic" ;;
	"700|normal") echo "Bold" ;;
	"700|italic") echo "Bold Italic" ;;
	*) echo "${style^}" ;;
	esac
}

# Rewrite the OpenType name table so each file keeps the correct family/subfamily
# metadata while still allowing the system to present the family as a coherent set.
update_font_metadata() {
	python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
from fontTools.ttLib import TTFont
font_path = sys.argv[1]
family_name = sys.argv[2]
subfamily_name = sys.argv[3]
weight = int(sys.argv[4])
font = TTFont(font_path)
name_table = font['name']
name_table.setName(family_name, 1, 3, 1, 0x409)
name_table.setName(subfamily_name, 2, 3, 1, 0x409)
name_table.setName(f"{family_name} {subfamily_name}", 4, 3, 1, 0x409)
name_table.setName(f"{family_name}-{subfamily_name}", 6, 3, 1, 0x409)
name_table.setName(family_name, 16, 3, 1, 0x409)
name_table.setName(subfamily_name, 17, 3, 1, 0x409)
if 'OS/2' in font:
    font['OS/2'].usWeightClass = weight
font.save(font_path)
PY
}

ensure_fonttools() {
	if python3 - <<'PY' >/dev/null 2>&1; then
import fontTools
PY
		return 0
	fi

	dnf install -y python3-pip python3-fonttools || true

	if ! python3 - <<'PY' >/dev/null 2>&1; then
import fontTools
PY
		python3 -m ensurepip --upgrade || true
		python3 -m pip install --user --break-system-packages --upgrade fonttools || true
	fi

	if ! python3 - <<'PY' >/dev/null 2>&1; then
import fontTools
PY
		echo "Unable to install fontTools for the active Python runtime: $(python3 -V 2>&1)" >&2
		exit 1
	fi
}

# Ensure the local toolchain is available before doing any downloads or metadata work.
require_cmd curl
require_cmd sha256sum
require_cmd python3
ensure_fonttools

# Embedded source list: family, weight, style, public URL, expected SHA-256.
# Keeping this in the script makes the build fully self-contained and reproducible.
FONT_ENTRIES=(
	'Boehringer Forward Head|400|normal|https://brand.boehringer-ingelheim.com/api/brand-essentials-font-file/GF1KAcG3ywtD1kSD8Tbg|4a1c6579c3199189879fb7c3ae88b2350550e7156f650149394bd193a6628135'
	'Boehringer Forward Head|400|italic|https://brand.boehringer-ingelheim.com/api/brand-essentials-font-file/JdkQLfUN27wCZs3AXP3c|febdca48e18d003d9a6e9c99342d8871cd971cbaeb5746231134f0acc897aedd'
	'Boehringer Forward Head|500|normal|https://brand.boehringer-ingelheim.com/api/brand-essentials-font-file/T6XNz2bG8MdP2z28U4Df|872af1e466026967da6268ae25026b5714775c9029b4654d18a3bc91480a0630'
	'Boehringer Forward Head|500|italic|https://brand.boehringer-ingelheim.com/api/brand-essentials-font-file/QmaAZXdppDNMp7arVVRV|0daff8fba4e596ac0465f0059dd716fc82427ba579448adbfdf3252291929122'
	'Boehringer Forward Head|700|normal|https://brand.boehringer-ingelheim.com/api/brand-essentials-font-file/f1EzwEgy2JVwDeR5QQ75|d2eb50c39d38008dc18eb9fd3c431628086d4fc1edfbb4cb0335ac14dd1ebd8b'
	'Boehringer Forward Head|700|italic|https://brand.boehringer-ingelheim.com/api/brand-essentials-font-file/qf4tHR4mWv9UzDuMDSuo|270150577c101ba7b629c6139cfbb89a87c4505417c5575c27b5fcfcadcc5138'
	'Boehringer Forward Text|400|normal|https://brand.boehringer-ingelheim.com/api/brand-essentials-font-file/7KysDCJ4ukKZqZyiV2wG|1e49ec75029972222c2c7d5ac658201d4194b7bcb7c04e5eb1081a2a82708ddb'
	'Boehringer Forward Text|400|italic|https://brand.boehringer-ingelheim.com/api/brand-essentials-font-file/Ae6YKDamqdw6P2MWmcUX|b1deb30d85742fccdd23c326a36edb4b7d75e1a2a0aa05c24196a62c848e3785'
	'Boehringer Forward Text|500|normal|https://brand.boehringer-ingelheim.com/api/brand-essentials-font-file/Djn6euHRHETJVmSzNrCM|c97233eb55ca43b115fe24d8b9f7e89b5678f388d1530c85e02f266a203d0508'
	'Boehringer Forward Text|500|italic|https://brand.boehringer-ingelheim.com/api/brand-essentials-font-file/f4F3QSjop7W8uuaNxkye|21439f960df58bd145bd4a8f2399ddd17604a70e2b10844443abc69c396dfa32'
	'Boehringer Forward Text|700|normal|https://brand.boehringer-ingelheim.com/api/brand-essentials-font-file/cJ2jd5EdXy5WE1L2a98m|18f7098a88bccf15a50887d324f2170801f2ed39b97009dd51f989b1d42f3f15'
	'Boehringer Forward Text|700|italic|https://brand.boehringer-ingelheim.com/api/brand-essentials-font-file/MS6p1a1hpVQYEiTbHLWa|2bc9ba184ee3506e874d9c7ec43fd3890e4c279a72b521f2f772911a8ed98645'
)

# Install into a dedicated system font directory and clean up temporary downloads.
mkdir -p "$OUTPUT_DIR"
if [[ ! -d "$OUTPUT_DIR" ]]; then
  echo "Unable to create font directory: $OUTPUT_DIR" >&2
  exit 1
fi
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

for entry in "${FONT_ENTRIES[@]}"; do
	IFS='|' read -r family weight style url expected_hash <<<"$entry"
	subfamily="$(subfamily_name "$weight" "$style")"
	family_slug="${family// /_}"
	output_name="${family_slug}-${subfamily// /_}.ttf"
	downloaded_path="$tmpdir/$output_name"

	# Download exactly the approved public file and verify its checksum before use.
	# The source endpoint blocks non-browser clients, so spoof a recent desktop browser.
	curl -fsSL \
		-A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0' \
		-H 'Accept: */*' \
		-H 'Accept-Language: en-US,en;q=0.9' \
		-H 'Referer: https://brand.boehringer-ingelheim.com/' \
		"$url" -o "$downloaded_path"
	actual_hash="$(sha256sum "$downloaded_path" | awk '{print $1}')"
	if [[ "$actual_hash" != "$expected_hash" ]]; then
		echo "Hash mismatch for $output_name: expected $expected_hash, got $actual_hash" >&2
		exit 1
	fi

	# Normalize the font metadata to keep the family/subfamily names consistent.
	update_font_metadata "$downloaded_path" "$family" "$subfamily" "$weight"
	cp -f "$downloaded_path" "$OUTPUT_DIR/$output_name"
	echo "Generated $OUTPUT_DIR/$output_name"
done

echo "Corporate font processing complete. Output: $OUTPUT_DIR"

# Refresh the font config so applications can see the newly installed faces.
if command -v fc-cache >/dev/null 2>&1; then
	fc-cache -fv "$OUTPUT_DIR" >/dev/null 2>&1 || true
else
	echo "fc-cache not found; skipping font cache refresh"
fi
