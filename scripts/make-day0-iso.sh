#!/usr/bin/env bash
# Terraform passes SOURCE and OUTPUT through environment variables.
# Select an available ISO tool and restrict the resulting file permissions.
set -euo pipefail
: "${SOURCE:?Set SOURCE to generated day0-config path}"
: "${OUTPUT:?Set OUTPUT to generated ISO path}"
[[ -f "$SOURCE" ]] || { echo "Missing $SOURCE" >&2; exit 1; }
mkdir -p "$(dirname "$OUTPUT")"
if command -v genisoimage >/dev/null 2>&1; then
  genisoimage -quiet -r -V DAY0 -o "$OUTPUT" "$SOURCE"
elif command -v mkisofs >/dev/null 2>&1; then
  mkisofs -quiet -r -V DAY0 -o "$OUTPUT" "$SOURCE"
elif command -v xorriso >/dev/null 2>&1; then
  xorriso -as mkisofs -quiet -r -V DAY0 -o "$OUTPUT" "$SOURCE"
else
  echo "Install genisoimage, mkisofs, or xorriso to generate Day-0 ISOs." >&2
  exit 1
fi
chmod 600 "$OUTPUT"
echo "Created $OUTPUT"
