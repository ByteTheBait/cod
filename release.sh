#!/usr/bin/env bash
#
# release.sh — build, tag, and release a new version of Cod.
#
# Usage:
#   ./release.sh <version> [--build N]
#
#   <version>   Semantic version in X.Y.Z form (e.g. 2.7.1). The build number
#               defaults to 1 and can be overridden with --build.
#
#   --build N   Build number appended after '+'. Defaults to 1.
#
# What it does:
#   1. Updates the version in pubspec.yaml
#   2. Builds the macOS release (with the Google/Supabase defines from .env)
#   3. Creates a DMG (Cod-<version>-MacOS.dmg) from the built app
#   4. Commits the version bump
#   5. Opens your terminal editor ($EDITOR, else vi) to write the tag's
#      subject and description
#   6. Creates an annotated git tag v<version>
#   7. Pushes the tag and (if `gh` is installed) creates a GitHub release
#
# Pre-release detection:
#   If the last number before the build number is NOT zero (e.g. 2.7.1+1),
#   the GitHub release is marked as a pre-release. A zero (e.g. 2.7.0+1) is a
#   stable release.

set -euo pipefail

VERSION=""
BUILD="1"

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build|-b)
      BUILD="$2"
      shift 2
      ;;
    --version|-v)
      VERSION="$2"
      shift 2
      ;;
    -h|--help)
      awk '/^#/{print substr($0,3)} /^[^#]/{exit}' "$0"
      exit 0
      ;;
    *)
      VERSION="$1"
      shift
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "Error: no version given." >&2
  echo "Usage: $0 <version> [--build N]" >&2
  exit 1
fi

# ── Validate version format X.Y.Z ─────────────────────────────────────────────
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: version must be in X.Y.Z form (e.g. 2.7.1)." >&2
  exit 1
fi
if [[ ! "$BUILD" =~ ^[0-9]+$ ]]; then
  echo "Error: build number must be an integer." >&2
  exit 1
fi

# ── Pre-release detection ─────────────────────────────────────────────────────
# The last number before the build number. If it's not zero → pre-release.
LAST_NUM="${VERSION##*.}"
if [[ "$LAST_NUM" != "0" ]]; then
  PRERELEASE=true
else
  PRERELEASE=false
fi

FULL_VERSION="${VERSION}+${BUILD}"
TAG="v${VERSION}"

echo "Version:   ${FULL_VERSION}"
echo "Tag:       ${TAG}"
echo "Pre-release: ${PRERELEASE}"

# ── Update pubspec.yaml ──────────────────────────────────────────────────────
if ! grep -q '^version:' pubspec.yaml; then
  echo "Error: no 'version:' line found in pubspec.yaml." >&2
  exit 1
fi
sed -i '' "s/^version: .*/version: ${FULL_VERSION}/" pubspec.yaml
echo "→ pubspec.yaml set to version ${FULL_VERSION}"

# ── Build ─────────────────────────────────────────────────────────────────────
if [[ ! -f .env ]]; then
  echo "Error: .env not found (needed for Google/Supabase defines)." >&2
  exit 1
fi
source "$(dirname "$0")/.env"

echo "→ Building macOS release..."
flutter build macos --release \
  --dart-define=GOOGLE_CLIENT_ID="$GOOGLE_CLIENT_ID" \
  --dart-define=GOOGLE_CLIENT_SECRET="$GOOGLE_CLIENT_SECRET" \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY"

# ── Create DMG ────────────────────────────────────────────────────────────────
APP_PATH="build/macos/Build/Products/Release/Cod.app"
DMG_NAME="Cod-${VERSION}-MacOS.dmg"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: built app not found at ${APP_PATH}." >&2
  exit 1
fi
echo "→ Creating ${DMG_NAME}..."
hdiutil create \
  -volname "Cod" \
  -srcfolder "$APP_PATH" \
  -ov \
  -format UDZO \
  "$DMG_NAME"
echo "→ DMG created: ${DMG_NAME}"

# ── Commit the version bump ────────────────────────────────────────────────────
git add pubspec.yaml
git commit -m "Bump version to ${VERSION}" >/dev/null
echo "→ Committed version bump"

# ── Editor for subject + description ─────────────────────────────────────────
TMPFILE="$(mktemp)"
cat > "$TMPFILE" <<EOF
# Release notes for ${TAG}
# ─────────────────────────────────────────────────────────────
# First line:  the subject (title) of the release.
# Blank line:  separates subject from description.
# Following:   the description (can be multiple lines).
# Lines starting with '#' are ignored.
# ─────────────────────────────────────────────────────────────

${VERSION}

Describe what changed in this release...
EOF

EDITOR_BIN="${EDITOR:-vi}"
echo "→ Opening ${EDITOR_BIN} to write release notes..."
"$EDITOR_BIN" "$TMPFILE"

# ── Parse subject + description ──────────────────────────────────────────────
# Strip comment lines, then take the first non-empty line as subject and the
# rest (after the first blank line) as the description.
CLEAN="$(grep -v '^#' "$TMPFILE" | sed '/^[[:space:]]*$/d')"
SUBJECT="$(echo "$CLEAN" | head -1)"
DESCRIPTION="$(echo "$CLEAN" | tail -n +2)"

if [[ -z "$SUBJECT" ]]; then
  echo "Error: no subject provided in the release notes." >&2
  rm -f "$TMPFILE"
  exit 1
fi

echo ""
echo "Subject:   ${SUBJECT}"
echo "Description:"
echo "${DESCRIPTION}"
echo ""

# ── Create annotated git tag ──────────────────────────────────────────────────
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Error: tag ${TAG} already exists." >&2
  rm -f "$TMPFILE"
  exit 1
fi

git tag -a "$TAG" -m "$SUBJECT" -m "$DESCRIPTION"
echo "→ Created annotated tag ${TAG}"

# ── Push tag ─────────────────────────────────────────────────────────────────
git push origin "$TAG"
echo "→ Pushed ${TAG}"

# ── Create GitHub release (if gh is available) ────────────────────────────────
if command -v gh >/dev/null 2>&1; then
  echo "→ Creating GitHub release..."
  if [[ "$PRERELEASE" == true ]]; then
    gh release create "$TAG" \
      --title "$SUBJECT" \
      --notes "$DESCRIPTION" \
      --prerelease
  else
    gh release create "$TAG" \
      --title "$SUBJECT" \
      --notes "$DESCRIPTION"
  fi
  echo "→ GitHub release created."
else
  echo "→ 'gh' not found — skipping GitHub release. Tag ${TAG} pushed."
fi

rm -f "$TMPFILE"
echo ""
echo "Done. Released ${TAG} (${FULL_VERSION})."
