#!/bin/bash

set -ouex pipefail

# install dependencies
dnf5 install woff2 wget -y

# define variables
tmpdir=$(mktemp -d)
base_url="https://www.boehringer-ingelheim.com/libraries/storybook/artifact/fonts"
fonts=(text headline)
font_sizes=(medium bold) # light not found (yet)
declare -A hash_values=(
	["text-medium"]="11333cee6d861e2901bf0106b7f59bbc0fe31bba5fa6af5532134ee0b319a10d"
	["text-bold"]="3442ad8713dd2aa3925a06f76af1a7a076f93bd8c7182dbf42a22884633bb472"
	["headline-medium"]="8189953810dcd74cd824fa86ab0984ee95415b19be6059ddad412a995a34757e"
	["headline-bold"]="8c87b6fe020ad2f1bac3d4eb61a7915315a1c87d672257e66e97e235fcaf32fb"
)

# download, verify, and convert fonts
for font in "${fonts[@]}"; do
	for size in "${font_sizes[@]}"; do
		url="$base_url/boehringer-$font/Boehringer${font^}-${size^}.woff2"
		wget -P "$tmpdir" "$url"

		file="Boehringer${font^}-${size^}.woff2"
		actual_hash=$(sha256sum "$tmpdir/$file" | awk '{print $1}')

		expected_hash="${hash_values["$font-$size"]}"

		if [[ "$actual_hash" != "$expected_hash" ]]; then
			echo "Hash mismatch for $file: expected $expected_hash, got $actual_hash"
			exit 1
		fi
		echo "Downloaded and verified $file successfully."

		woff2_decompress "$tmpdir/$file"
	done
done

# move the downloaded fonts to the appropriate directory
mkdir -p /usr/share/fonts/boehringer
mv "$tmpdir"/*.ttf /usr/share/fonts/boehringer/
rm -rf "$tmpdir"

# reload font cache
fc-cache -f -v
