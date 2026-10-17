#!/usr/bin/env bash
#
# ship.sh — cut a full Overlap release in one go:
#   preflight → version bump → tests → build/sign/notarize (release.sh)
#   → tag → push → GitHub release → install to /Applications
#
# Usage:  ./scripts/ship.sh 0.5 [--notes FILE] [--yes] [--no-install] [--skip-build]
#
#   --yes          don't ask before publishing (needed when there's no
#                  terminal to answer in, e.g. `! ./scripts/ship.sh` in Claude)
#   --skip-build   reuse the notarized dist/Overlap-<version>.zip from an
#                  earlier run that stopped before publishing
#
# Release notes default to docs/releases/<version>.md. If that file doesn't
# exist, a draft is written there from the commits since the last tag and the
# script stops so you can edit it, then run it again.
#
# Nothing leaves your Mac until after the build is notarized, and the script
# asks once before tagging/pushing/publishing (skip with --yes).
#
set -euo pipefail
cd "$(dirname "$0")/.."

# ---------- args ----------
VERSION=""
NOTES=""
ASSUME_YES=0
INSTALL=1
SKIP_BUILD=0
while [ $# -gt 0 ]; do
    case "$1" in
        --notes) NOTES="$2"; shift 2 ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        --no-install) INSTALL=0; shift ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) VERSION="$1"; shift ;;
    esac
done
if [ -z "$VERSION" ]; then
    echo "usage: $0 <version> [--notes FILE] [--yes] [--no-install] [--skip-build]" >&2
    exit 2
fi
VERSION="${VERSION#v}"
TAG="v$VERSION"
NOTES="${NOTES:-docs/releases/$VERSION.md}"
ZIP="dist/Overlap-$VERSION.zip"

step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- preflight ----------
step "Preflight for $TAG"

[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || fail "not on main"

email="$(git config user.email)"
case "$email" in
    *@users.noreply.github.com) ;;
    *) fail "git user.email is '$email' — GitHub rejects pushes that expose a private email. Use the noreply address." ;;
esac

# Only the version file and the notes may be uncommitted.
dirty="$(git status --porcelain | grep -v -e ' project.yml$' -e " $NOTES\$" || true)"
[ -z "$dirty" ] || fail "uncommitted changes:
$dirty"

if [ "$ASSUME_YES" -ne 1 ] && [ ! -t 0 ]; then
    fail "no terminal to confirm publishing in — rerun with --yes"
fi
if [ "$SKIP_BUILD" -eq 1 ] && [ ! -f "$ZIP" ]; then
    fail "--skip-build but $ZIP doesn't exist"
fi

command -v xcodegen >/dev/null || fail "xcodegen not installed"
gh auth status >/dev/null 2>&1 || fail "gh is not logged in (run: gh auth login)"
repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
[ "$(gh api "repos/$repo" -q .permissions.push 2>/dev/null)" = "true" ] ||
    fail "active gh account '$(gh api user -q .login)' can't publish releases on $repo (switch with: gh auth switch)"

git fetch --quiet origin --tags
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    fail "$TAG already exists on GitHub — pick a new version"
fi

if [ ! -f "$NOTES" ]; then
    mkdir -p "$(dirname "$NOTES")"
    last="$(git describe --tags --abbrev=0 2>/dev/null || true)"
    {
        echo "## Overlap $VERSION"
        echo
        echo "### Changes"
        git log --no-merges --format='- %s' ${last:+"$last"..HEAD}
    } > "$NOTES"
    echo "Wrote a draft to $NOTES from commits since ${last:-the start}."
    echo "Edit it, then run this again."
    exit 1
fi

# ---------- version bump ----------
step "Version"
current="$(grep -m1 MARKETING_VERSION project.yml | awk '{print $2}' | tr -d '"')"
if [ "$current" != "$VERSION" ]; then
    sed -i '' "s/MARKETING_VERSION: \"$current\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
    echo "project.yml: $current → $VERSION"
fi
git add project.yml "$NOTES"
if ! git diff --cached --quiet; then
    git commit -q -m "Prepare release $VERSION"
    echo "committed: Prepare release $VERSION"
else
    echo "already at $VERSION"
fi

# ---------- tests ----------
step "Tests"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
( cd scripts/fixtures/mocksource && swiftc main.swift -o mocksource )
cp scripts/test-sources.swift "$scratch/main.swift"
swiftc Sources/PluginContract.swift Sources/SourceContract.swift Sources/PluginProcess.swift \
    Sources/FileOrigin.swift Sources/SourceEngine.swift Sources/TagIO.swift Sources/PluginRegistry.swift \
    "$scratch/main.swift" -o "$scratch/test-sources" 2>/dev/null
"$scratch/test-sources" | tail -1

# ---------- build, sign, notarize ----------
if [ "$SKIP_BUILD" -eq 1 ]; then
    step "Build + notarize (skipped — reusing $ZIP)"
    xcrun stapler validate dist/Overlap.app >/dev/null || fail "dist/Overlap.app isn't notarized/stapled"
else
    step "Build + notarize"
    ./scripts/release.sh
    [ -f "$ZIP" ] || fail "release.sh finished but $ZIP is missing"

    # release.sh rebuilds the plugin binaries with -O; keep the committed ones
    # so the tree stays clean (the shipped app has the fresh builds).
    git checkout -- plugins/*/ 2>/dev/null || true
fi

# ---------- publish ----------
step "Publish"
echo "About to:"
echo "  • tag $TAG at $(git rev-parse --short HEAD)"
echo "  • push main and $TAG to $(git remote get-url origin)"
echo "  • create GitHub release $TAG with $ZIP and $NOTES"
if [ "$ASSUME_YES" -ne 1 ]; then
    read -r -p "Go? [y/N] " answer
    [ "$answer" = "y" ] || [ "$answer" = "Y" ] || fail "stopped before publishing (build is in dist/)"
fi

git tag -fa "$TAG" -m "Overlap $VERSION"
git push origin main "$TAG"
gh release create "$TAG" "$ZIP" --title "Overlap $VERSION" --notes-file "$NOTES"

# ---------- install ----------
if [ "$INSTALL" -eq 1 ]; then
    step "Install"
    osascript -e 'quit app "Overlap"' 2>/dev/null || true
    sleep 1
    ditto dist/Overlap.app /Applications/Overlap.app
    echo "installed /Applications/Overlap.app"
fi

step "Shipped $TAG"
gh release view "$TAG" --json url -q .url
