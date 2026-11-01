#!/bin/bash
# Release notes for a tag: its CHANGELOG.md section, else commit subjects since the previous release.
# Usage: scripts/release-notes.sh <vX.Y.Z> | --commits [ref]
set -euo pipefail
cd "$(dirname "$0")/.."

# Only vX.Y.Z tags are releases
previous() { git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' "$1" 2> /dev/null || true; }

commits() {
    local prev
    prev=$(previous "$1")
    git log --no-merges --format='- %s' "${prev:+$prev..}$2" | grep -v -E '^- Release v[0-9]' || true
}

section() {
    [[ -f CHANGELOG.md ]] || return 0
    awk -v v="${1#v}" '
        /^## / { if (found) exit; h = $2; sub(/^v/, "", h); found = (h == v); next }
        found { lines[++n] = $0 }
        END {
            s = 1; while (s <= n && lines[s] ~ /^[[:space:]]*$/) s++
            e = n; while (e >= s && lines[e] ~ /^[[:space:]]*$/) e--
            for (i = s; i <= e; i++) print lines[i]
        }' CHANGELOG.md
}

if [[ "${1:-}" == --commits ]]; then
    ref="${2:-HEAD}"
    commits "$ref" "$ref"
    exit
fi

tag="${1:?Usage: $0 <vX.Y.Z> | --commits [ref]}"
notes=$(section "$tag")
[[ -n "$notes" ]] || notes=$(commits "$tag^" "$tag")
echo "$notes"
prev=$(previous "$tag^")
if [[ -n "$prev" && -n "${GITHUB_REPOSITORY:-}" ]]; then
    printf '\n**Full Changelog**: https://github.com/%s/compare/%s...%s\n' "$GITHUB_REPOSITORY" "$prev" "$tag"
fi
