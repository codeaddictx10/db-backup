#!/usr/bin/env bash
# Regenerate supercronic SHA1 checksums for the Dockerfile case block.
# Run this ONLY when bumping SUPERCRONIC_VERSION or adding an architecture.
#
#   ./scripts/update-checksums.sh v0.2.34
#
set -euo pipefail

VERSION="${1:?usage: $0 <supercronic-version>   e.g. v0.2.34}"
ARCHES=(amd64 arm64 arm)

# macOS has no sha1sum; Linux has no shasum by default
if command -v sha1sum >/dev/null; then HASH="sha1sum"; else HASH="shasum -a 1"; fi

echo "supercronic ${VERSION}"
echo

for arch in "${ARCHES[@]}"; do
  url="https://github.com/aptible/supercronic/releases/download/${VERSION}/supercronic-linux-${arch}"
  tmp="$(mktemp)"

  if ! curl -fsSL -o "$tmp" "$url"; then
    echo "  ${arch}: DOWNLOAD FAILED — check the version tag" >&2
    rm -f "$tmp"; continue
  fi

  size=$(wc -c < "$tmp" | tr -d ' ')
  sum=$($HASH "$tmp" | cut -d' ' -f1)
  rm -f "$tmp"

  # a real binary is ~13MB; anything tiny is an error page
  (( size > 1000000 )) || { echo "  ${arch}: SUSPICIOUS — only ${size} bytes" >&2; continue; }

  printf '      %-6s) SHA1=%s ;;   # %s bytes\n' "$arch" "$sum" "$size"
done

echo
echo "Paste the lines above into the Dockerfile case block."
echo "Update SUPERCRONIC_VERSION to ${VERSION} in the SAME commit."
