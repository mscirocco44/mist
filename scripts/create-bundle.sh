#!/bin/bash
set -euo pipefail
# create-bundle.sh: Package the full Mist repo + all downloads into one tarball.
#
# Run this AFTER download-deps.sh has populated downloads/.
# Upload the resulting mist-bundle-<version>.tar.gz to a GitHub Release so
# users can download a single file and deploy without internet access.
#
# Usage: ./scripts/create-bundle.sh [version]
#   version  optional tag, e.g. v1.0.0 (defaults to current date)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION="${1:-$(date '+%Y%m%d')}"
BUNDLE="mist-bundle-${VERSION}.tar.gz"
OUTPUT="$BASE_DIR/$BUNDLE"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

# Verify downloads are populated
required=(
    downloads/prometheus.tar
    downloads/grafana.tar
    downloads/containerd.io*.rpm
    downloads/docker-ce-*.rpm
    downloads/alloy*.rpm
    downloads/node_exporter*.tar.gz
)
for pat in "${required[@]}"; do
    matches=("$BASE_DIR"/$pat)
    if [ ${#matches[@]} -eq 0 ] || [ ! -f "${matches[0]}" ]; then
        echo "ERROR: missing $pat — run scripts/download-deps.sh first" >&2
        exit 1
    fi
done

log "Creating bundle: $BUNDLE"
tar -czf "$OUTPUT" \
    --exclude='.git' \
    --exclude='*.tar.gz' \
    --transform "s|^\.|mist|" \
    -C "$BASE_DIR" .

# Re-add the bundle itself is excluded, but we need to include downloads/
# Rebuild properly: exclude the output file and .git, include everything else
rm -f "$OUTPUT"
tar -czf "$OUTPUT" \
    -C "$(dirname "$BASE_DIR")" \
    --exclude="$(basename "$BASE_DIR")/.git" \
    --exclude="$(basename "$BASE_DIR")/$BUNDLE" \
    "$(basename "$BASE_DIR")"

SIZE=$(du -sh "$OUTPUT" | cut -f1)
log "Bundle created: $OUTPUT ($SIZE)"
log ""
log "Next steps:"
log "  1. Create a GitHub release: gh release create $VERSION --title 'Mist $VERSION'"
log "  2. Upload bundle:           gh release upload $VERSION $OUTPUT"
log "  3. Users download:          gh release download $VERSION"
