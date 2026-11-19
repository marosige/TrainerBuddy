#!/usr/bin/env bash
# Builds the CurseForge upload: dist/TrainerBuddy-<version>.zip, holding a single
# TrainerBuddy/ folder with only the files the game needs.
# Needs nothing but git, so it runs in Git Bash on Windows as well as on macOS / Linux.
#
#   ./make-zip.sh
set -euo pipefail

ADDON=TrainerBuddy
# everything that goes into the zip; add new textures / Lua files here
FILES=(TrainerBuddy.toc TrainerBuddy.lua icon.tga paper.tga portrait.tga)

cd "$(dirname "$0")"

version=$(sed -n 's/^## Version:[[:space:]]*//p' "$ADDON.toc" | tr -d '\r')
if [ -z "$version" ]; then
    echo "No '## Version:' line in $ADDON.toc" >&2
    exit 1
fi

# Safety net: every file the TOC loads and every Interface\AddOns\TrainerBuddy\... path
# in the code must be in FILES, and every file in FILES must be committed to git.
needed=$(
    {
        grep -v '^#' "$ADDON.toc" | tr -d '\r' | sed '/^[[:space:]]*$/d'
        grep -ohE 'AddOns[\\/]+'"$ADDON"'[\\/]+[A-Za-z0-9_./\\-]+' "$ADDON.toc" ./*.lua |
            sed -E 's#^AddOns[\\/]+'"$ADDON"'[\\/]+##; s#[\\]+#/#g'
    } | sort -u
)
ok=1
for f in $needed; do
    case " ${FILES[*]} " in
        *" $f "*) ;;
        *) echo "Needed by the addon but not in FILES: $f" >&2; ok=0 ;;
    esac
done
for f in "${FILES[@]}"; do
    if ! git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
        echo "Not committed to git (git add it first): $f" >&2
        ok=0
    fi
done
[ "$ok" = 1 ] || exit 1

# Uncommitted edits to the packaged files are included, with a warning.
tree=HEAD
if ! git diff --quiet HEAD -- "${FILES[@]}"; then
    echo "Warning: uncommitted changes in the packaged files are included in the zip." >&2
    tree=$(git stash create)   # a commit of the working tree; nothing is actually stashed
fi

mkdir -p dist
out="dist/$ADDON-$version.zip"
rm -f "$out"
git archive --format=zip --prefix="$ADDON/" -o "$out" "$tree" "${FILES[@]}"

echo "Built $out"
if command -v unzip >/dev/null 2>&1; then
    unzip -l "$out"
fi
