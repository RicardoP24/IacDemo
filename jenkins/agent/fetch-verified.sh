#!/usr/bin/env bash
# Download a release artifact and verify its SHA-256 against the publisher's checksum file.
# Usage: fetch-verified <artifact-url> <checksums-url>
set -euo pipefail

url=$1
sums_url=$2
name=$(basename "$url")

curl -fsSLo "$name" "$url"
curl -fsSLo "$name.sums" "$sums_url"

# Checksum files list "<sha256>  <file>"; some (kubectl) contain only the hash.
if [ "$(wc -w < "$name.sums")" -eq 1 ]; then
    expected=$(cat "$name.sums")
else
    expected=$(awk -v n="$name" '$2 == n || $2 == "*"n || $2 == "./"n { print $1 }' "$name.sums")
fi

if [ -z "$expected" ]; then
    echo "fetch-verified: no checksum found for $name" >&2
    exit 1
fi

echo "$expected  $name" | sha256sum -c -
rm -f "$name.sums"
