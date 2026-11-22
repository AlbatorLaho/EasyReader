#!/bin/bash
# Adds a CHANGELOG.md section from commits since the last release, opens $EDITOR, commits and tags (no push).
# Usage: scripts/prepare-release.sh <X.Y.Z>
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1#v}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage: $0 <X.Y.Z>" >&2; exit 1; }
tag="v$version"
editor="${VISUAL:-${EDITOR:-}}"
if [[ -z "$editor" ]] || ! command -v "${editor%% *}" > /dev/null; then echo "Set VISUAL or EDITOR to your editor" >&2; exit 1; fi
if git rev-parse -q --verify "refs/tags/$tag" > /dev/null; then echo "Tag $tag already exists" >&2; exit 1; fi
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then echo "Commit or stash your changes first" >&2; exit 1; fi
xcrun swift-format lint --strict -r --parallel EasyReader EasyReaderTests || { echo "Fix the lint warnings first (xcrun swift-format format -i -r EasyReader EasyReaderTests)" >&2; exit 1; }

tracked=$(git ls-files CHANGELOG.md)
restore() {
    git checkout -q -- EasyReader.xcodeproj/project.pbxproj
    if [[ -n "$tracked" ]]; then git checkout -q -- CHANGELOG.md; else rm -f CHANGELOG.md; fi
    rm -f CHANGELOG.md.new
    echo "Aborted; changes reverted"
}
trap restore ERR
trap 'restore; exit 130' INT

[[ -f CHANGELOG.md ]] || printf '# Changelog\n' > CHANGELOG.md
if grep -qE "^## v?$version( |$)" CHANGELOG.md; then
    echo "CHANGELOG.md already has a $version section; editing it"
else
    entries=$(scripts/release-notes.sh --commits HEAD)
    section="## $version - $(date +%F)

${entries:-- }
"
    SECTION="$section" awk '!done && /^## / { print ENVIRON["SECTION"]; done = 1 } { print } END { if (!done) print "\n" ENVIRON["SECTION"] }' \
        CHANGELOG.md > CHANGELOG.md.new
    mv CHANGELOG.md.new CHANGELOG.md
fi

$editor CHANGELOG.md
notes=$(scripts/release-notes.sh "$tag")
if ! grep -qE "^## v?$version( |$)" CHANGELOG.md || [[ -z "$notes" ]]; then
    echo "No notes in the $version section" >&2
    restore
    exit 1
fi

sed -i '' -E "s/(MARKETING_VERSION = )[^;]*;/\1$version;/" EasyReader.xcodeproj/project.pbxproj
if [[ "$(grep -oE 'MARKETING_VERSION = [^;]*;' EasyReader.xcodeproj/project.pbxproj | sort -u)" != "MARKETING_VERSION = $version;" ]]; then
    echo "Couldn't set MARKETING_VERSION to $version" >&2
    restore
    exit 1
fi

printf '\n%s\n\n' "$notes"
read -r -p "Commit and tag $tag? [y/N] " answer
if [[ "$answer" != [yY]* ]]; then
    restore
    exit 1
fi
trap - ERR INT
git add CHANGELOG.md EasyReader.xcodeproj/project.pbxproj
git commit -q -m "Release $tag"
git tag -a "$tag" -m "Release $tag"
echo "Tagged $tag. Publish: git push origin $tag   (and push your branch)"
