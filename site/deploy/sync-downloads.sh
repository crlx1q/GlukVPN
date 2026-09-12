#!/usr/bin/env bash
#
# GlukVPN release sync: two files in, everything else derived.
#
# Until now a release meant editing the version by hand in seven places - the
# HTML buttons, config.js, ui.js, api/version.json and the nginx config - and
# one of them was always missed. The site shipped 1.6.0 while ui.js still had
# a hardcoded download="GlukVPN-Setup-1.5.0.exe", so the browser saved the new
# installer under the old name.
#
# The pages no longer know any version: every button points at /download/windows
# or /download/android, and those endpoints are redirects generated from what is
# actually in the downloads directory. So the release procedure is:
#
#   1. upload GlukVPN-Setup-X.Y.Z.exe and glukvpn-release-X.Y.Z.apk
#   2. run this script
#
# It reads the version out of the file names, writes api/version.json (the
# manifest desktop, Android and the extension poll for updates), regenerates
# the two nginx redirects, and fixes ownership and permissions. Everything it
# derives is derived from the files themselves, so running it twice in a row
# changes nothing.
#
# Usage:
#   ./sync-downloads.sh [options]
#
#   --root DIR             site root, default /var/www/vpn.gluk.tech
#   --downloads DIR        installers directory, default <root>/downloads
#   --api-dir DIR          where version.json goes, default <root>/api
#   --nginx-snippet FILE   redirect config to generate
#                          default /etc/glukvpn/nginx/downloads.conf
#   --owner USER:GROUP     owner for the files it touches, default www-data:www-data
#   --changelog TEXT       one-line changelog for this release
#   --changelog-file FILE  same, read from a file (for CI)
#   --min-supported X.Y.Z  raise the forced-upgrade floor (rarely; it turns the
#                          client's update banner into a blocking notice)
#   --build N              override the build number instead of deriving it
#   --prune                delete older installers, leaving exactly two files
#   --attachment           also force Content-Disposition: attachment on /downloads/
#   --dry-run              print what would change, write nothing
#   --no-reload            write, test, but do not reload nginx
#   --json                 print the resulting manifest fields as JSON
#   -h, --help             this text

set -euo pipefail

ROOT="/var/www/vpn.gluk.tech"
DOWNLOADS=""
API_DIR=""
NGINX_SNIPPET="/etc/glukvpn/nginx/downloads.conf"
OWNER="www-data:www-data"
CHANGELOG=""
CHANGELOG_FILE=""
MIN_SUPPORTED=""
BUILD_OVERRIDE=""
DO_PRUNE=0
DO_ATTACHMENT=0
DO_DRY=0
DO_RELOAD=1
DO_JSON=0

while [ $# -gt 0 ]; do
	case "$1" in
		--root) ROOT="${2:?}"; shift 2 ;;
		--downloads) DOWNLOADS="${2:?}"; shift 2 ;;
		--api-dir) API_DIR="${2:?}"; shift 2 ;;
		--nginx-snippet) NGINX_SNIPPET="${2:?}"; shift 2 ;;
		--owner) OWNER="${2:?}"; shift 2 ;;
		--changelog) CHANGELOG="${2:?}"; shift 2 ;;
		--changelog-file) CHANGELOG_FILE="${2:?}"; shift 2 ;;
		--min-supported) MIN_SUPPORTED="${2:?}"; shift 2 ;;
		--build) BUILD_OVERRIDE="${2:?}"; shift 2 ;;
		--prune) DO_PRUNE=1; shift ;;
		--attachment) DO_ATTACHMENT=1; shift ;;
		--dry-run) DO_DRY=1; shift ;;
		--no-reload) DO_RELOAD=0; shift ;;
		--json) DO_JSON=1; shift ;;
		-h|--help) sed -n '1,43p' "$0"; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

DOWNLOADS="${DOWNLOADS:-$ROOT/downloads}"
API_DIR="${API_DIR:-$ROOT/api}"
API_JSON="$API_DIR/version.json"

say() { printf '%s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*" >&2; }
die() { printf 'ERROR %s\n' "$*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || die "python3 is required to write $API_JSON safely"
[ -d "$DOWNLOADS" ] || die "downloads directory not found: $DOWNLOADS"

# ---------------------------------------------------------------------------
# 1. Which two files are we publishing?
#
# A name without a version is rejected rather than published: build-apk.yml has
# historically produced a bare glukvpn-release.apk, and a manifest that points
# at an unversioned file makes every future release invisible to clients - they
# compare versions, and the version would never change.
# ---------------------------------------------------------------------------
newest_matching() {
	# Newest by version, not by mtime: re-uploading an old installer must not
	# demote the site to it.
	find "$DOWNLOADS" -maxdepth 1 -type f -name "$1" -printf '%f\n' 2>/dev/null | sort -V -r
}

check_unversioned() {
	local name="$1"
	if [ -f "$DOWNLOADS/$name" ]; then
		die "$DOWNLOADS/$name has no version in its name. Rename it to the X.Y.Z form before publishing: clients compare versions, and an unversioned file freezes them on whatever they already have"
	fi
}

check_unversioned "GlukVPN-Setup.exe"
check_unversioned "glukvpn-release.apk"

EXE_ALL="$(newest_matching 'GlukVPN-Setup-*.exe' || true)"
APK_ALL="$(newest_matching 'glukvpn-release-*.apk' || true)"
[ -n "$EXE_ALL" ] || die "no GlukVPN-Setup-X.Y.Z.exe in $DOWNLOADS"
[ -n "$APK_ALL" ] || die "no glukvpn-release-X.Y.Z.apk in $DOWNLOADS"

EXE="$(printf '%s\n' "$EXE_ALL" | head -1)"
APK="$(printf '%s\n' "$APK_ALL" | head -1)"

version_of() {
	# The trailing `|| true` matters: without it a file like
	# GlukVPN-Setup-beta.exe would kill the script through set -e instead of
	# reaching the explicit error below.
	printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true
}

EXE_VERSION="$(version_of "$EXE")"
APK_VERSION="$(version_of "$APK")"
[ -n "$EXE_VERSION" ] || die "cannot read a X.Y.Z version out of $EXE"
[ -n "$APK_VERSION" ] || die "cannot read a X.Y.Z version out of $APK"

if [ "$EXE_VERSION" != "$APK_VERSION" ]; then
	# Not fatal: a platform sometimes ships a day late. The manifest carries one
	# version, so it has to be the newer one - the alternative is telling users
	# on the newer build that an update is available and handing them an older
	# installer.
	warn "version mismatch: $EXE is $EXE_VERSION, $APK is $APK_VERSION"
	VERSION="$(printf '%s\n%s\n' "$EXE_VERSION" "$APK_VERSION" | sort -V -r | head -1)"
	warn "publishing $VERSION; the other platform will report an update it cannot install until its file is uploaded"
else
	VERSION="$EXE_VERSION"
fi

# "Exactly two files" is the contract. Extra installers are not deleted without
# being asked: on a live server an unexpected file may be a rollback target.
EXTRA="$(printf '%s\n%s\n' "$EXE_ALL" "$APK_ALL" | sed '/^$/d' | grep -vFx "$EXE" | grep -vFx "$APK" || true)"
if [ -n "$EXTRA" ]; then
	if [ "$DO_PRUNE" = "1" ] && [ "$DO_DRY" != "1" ]; then
		while IFS= read -r stale; do
			[ -n "$stale" ] || continue
			rm -f -- "$DOWNLOADS/$stale"
			say "pruned $stale"
		done <<<"$EXTRA"
	else
		warn "$DOWNLOADS holds more than the two published files:"
		while IFS= read -r stale; do
			[ -n "$stale" ] || continue
			printf '  %s\n' "$stale" >&2
		done <<<"$EXTRA"
		warn "they are reachable by direct link; pass --prune to delete them"
	fi
fi

# ---------------------------------------------------------------------------
# 2. Manifest fields
#
# releaseDate comes from the file, not from today: re-running the script a week
# later must not claim a new release date. The build number only moves when the
# version does, for the same reason.
# ---------------------------------------------------------------------------
newest_mtime() {
	stat -c '%Y' "$DOWNLOADS/$EXE" "$DOWNLOADS/$APK" 2>/dev/null | sort -n -r | head -1
}
RELEASE_DATE="$(date -u -d "@$(newest_mtime)" '+%Y-%m-%d' 2>/dev/null || date -u '+%Y-%m-%d')"

if [ -n "$CHANGELOG_FILE" ]; then
	[ -f "$CHANGELOG_FILE" ] || die "changelog file not found: $CHANGELOG_FILE"
	CHANGELOG="$(tr '\n' ' ' <"$CHANGELOG_FILE" | sed 's/[[:space:]]\{2,\}/ /g; s/^ //; s/ $//')"
fi

SNIPPET_TARGET_WIN="/downloads/$EXE"
SNIPPET_TARGET_APK="/downloads/$APK"

say "publishing $VERSION"
say "  windows: $EXE"
say "  android: $APK"
say "  /download/windows -> $SNIPPET_TARGET_WIN"
say "  /download/android -> $SNIPPET_TARGET_APK"

# ---------------------------------------------------------------------------
# 3. api/version.json
#
# Rewritten field by field, not from a template: changelog, minSupportedVersion
# and the optional `extension` block are edited by hand or by another release
# step, and this script has no business dropping them.
# ---------------------------------------------------------------------------
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sync-downloads.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
NEW_JSON="$TMP_DIR/version.json"

SYNC_VERSION="$VERSION" \
SYNC_RELEASE_DATE="$RELEASE_DATE" \
SYNC_WINDOWS="$SNIPPET_TARGET_WIN" \
SYNC_ANDROID="$SNIPPET_TARGET_APK" \
SYNC_CHANGELOG="$CHANGELOG" \
SYNC_MIN_SUPPORTED="$MIN_SUPPORTED" \
SYNC_BUILD="$BUILD_OVERRIDE" \
python3 - "$API_JSON" "$NEW_JSON" <<'PY'
import json
import os
import sys

src, dst = sys.argv[1], sys.argv[2]

try:
    with open(src, encoding="utf-8") as fh:
        old = json.load(fh)
    if not isinstance(old, dict):
        old = {}
except FileNotFoundError:
    old = {}
except ValueError as exc:
    # A manifest the clients cannot parse is the same as no manifest, so a
    # broken file is replaced rather than inherited - but loudly.
    print("WARN  %s is not valid JSON (%s); writing a fresh manifest" % (src, exc),
          file=sys.stderr)
    old = {}

version = os.environ["SYNC_VERSION"]

# The build number is what a client compares when two releases share a version
# string; it may only move forward.
old_build = old.get("build")
old_build = old_build if isinstance(old_build, int) else 0
override = os.environ.get("SYNC_BUILD", "").strip()
if override:
    build = int(override)
elif old.get("version") == version:
    build = old_build or 1
else:
    build = old_build + 1

new = dict(old)
new["version"] = version
new["build"] = build
new["releaseDate"] = os.environ["SYNC_RELEASE_DATE"]
changelog = os.environ.get("SYNC_CHANGELOG", "").strip()
if changelog:
    new["changelog"] = changelog
else:
    new.setdefault("changelog", "")
# Site-relative on purpose: the same manifest works on beta and on any mirror.
# These stay versioned paths because the clients download them directly, and a
# redirect is one more thing that can fail inside an installer's HTTP client.
new["downloads"] = {
    "windows": os.environ["SYNC_WINDOWS"],
    "android": os.environ["SYNC_ANDROID"],
}
# The permanent endpoints, for anything that would rather not care about file
# names at all - the website already uses only these.
new["endpoints"] = {"windows": "/download/windows", "android": "/download/android"}
min_supported = os.environ.get("SYNC_MIN_SUPPORTED", "").strip()
if min_supported:
    new["minSupportedVersion"] = min_supported
else:
    new.setdefault("minSupportedVersion", "1.0.0")

# Stable key order so a release shows up as a three-line diff, and no
# generatedAt field: an idempotent script must produce an identical file.
lead = ["version", "build", "releaseDate", "changelog", "downloads", "endpoints",
        "minSupportedVersion"]
ordered = {key: new[key] for key in lead if key in new}
for key, value in new.items():
    ordered.setdefault(key, value)

with open(dst, "w", encoding="utf-8") as fh:
    json.dump(ordered, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY

# ---------------------------------------------------------------------------
# 4. nginx redirects
# ---------------------------------------------------------------------------
NEW_SNIPPET="$TMP_DIR/downloads.conf"
{
	echo "# Generated by site/deploy/sync-downloads.sh - DO NOT EDIT."
	echo "# Regenerate by uploading the two installers and running the script again."
	echo "#"
	echo "# Include this from the vpn.gluk.tech server block:"
	echo "#     include $NGINX_SNIPPET;"
	echo "#"
	echo "# The site links only to these two endpoints, so a release never touches a"
	echo "# page. 302 and not 301: the target changes with every release, and a"
	echo "# browser that cached a permanent redirect would keep downloading the old"
	echo "# installer long after it was deleted."
	echo "location = /download/windows {"
	echo "    return 302 $SNIPPET_TARGET_WIN;"
	echo "}"
	echo ""
	echo "location = /download/android {"
	echo "    return 302 $SNIPPET_TARGET_APK;"
	echo "}"
	if [ "$DO_ATTACHMENT" = "1" ]; then
		echo ""
		echo "# Optional: name the file in the response itself, for a client that follows"
		echo "# the redirect without keeping the final URL. Off by default because an"
		echo "# add_header here replaces the ones inherited from the server block."
		echo "location ^~ /downloads/ {"
		echo "    add_header Content-Disposition 'attachment' always;"
		echo "    add_header X-Content-Type-Options 'nosniff' always;"
		echo "}"
	fi
} >"$NEW_SNIPPET"

if [ "$DO_DRY" = "1" ]; then
	say ""
	say "--- $API_JSON (not written; --dry-run) ---"
	cat "$NEW_JSON"
	say "--- $NGINX_SNIPPET (not written; --dry-run) ---"
	cat "$NEW_SNIPPET"
	exit 0
fi

# ---------------------------------------------------------------------------
# 5. Write, verify, reload
# ---------------------------------------------------------------------------
OWNER_USER="${OWNER%%:*}"
fix_owner() {
	local path="$1"
	# A permission problem is reported, never fatal: by this point the release
	# is already published, and exiting here would leave a half-synced server.
	chmod 0644 "$path" 2>/dev/null || warn "could not chmod 644 $path"
	if [ "$(id -u)" = "0" ]; then
		chown "$OWNER" "$path" 2>/dev/null || warn "could not chown $OWNER $path"
	elif [ "$(id -un)" != "$OWNER_USER" ]; then
		warn "not root: left $path owned by $(id -un), wanted $OWNER"
	fi
}

mkdir -p "$API_DIR"
# Atomic: a client polling mid-write must never read half a manifest.
install -m 0644 "$NEW_JSON" "$API_JSON.tmp"
mv -f "$API_JSON.tmp" "$API_JSON"
fix_owner "$API_JSON"
say "wrote $API_JSON"

fix_owner "$DOWNLOADS/$EXE"
fix_owner "$DOWNLOADS/$APK"

SNIPPET_CHANGED=1
if [ -f "$NGINX_SNIPPET" ] && cmp -s "$NEW_SNIPPET" "$NGINX_SNIPPET"; then
	SNIPPET_CHANGED=0
	say "$NGINX_SNIPPET already current"
else
	mkdir -p "$(dirname "$NGINX_SNIPPET")"
	BACKUP=""
	if [ -f "$NGINX_SNIPPET" ]; then
		BACKUP="${NGINX_SNIPPET}.$(date -u '+%Y%m%d%H%M%S').bak"
		cp -p "$NGINX_SNIPPET" "$BACKUP"
	fi
	install -m 0644 "$NEW_SNIPPET" "$NGINX_SNIPPET"
	say "wrote $NGINX_SNIPPET"

	if command -v nginx >/dev/null 2>&1; then
		if ! nginx -t; then
			if [ -n "$BACKUP" ]; then
				cp -p "$BACKUP" "$NGINX_SNIPPET"
				say "restored $NGINX_SNIPPET from $BACKUP"
			else
				rm -f "$NGINX_SNIPPET"
				say "removed $NGINX_SNIPPET"
			fi
			die "nginx -t failed; the redirects were not changed (version.json was)"
		fi
	else
		warn "nginx not on PATH; config was written but not verified"
	fi
fi

# Reloading is pointless - and reload failures are confusing - while nothing
# includes the snippet yet. `nginx -T` is the only honest way to tell.
INCLUDED=0
if command -v nginx >/dev/null 2>&1 && nginx -T 2>/dev/null | grep -qF "$SNIPPET_TARGET_WIN"; then
	INCLUDED=1
fi

if [ "$INCLUDED" != "1" ]; then
	warn "no server block includes $NGINX_SNIPPET yet, so /download/windows still 404s"
	say "    add this inside the vpn.gluk.tech server{} block, then reload nginx:"
	say "        include $NGINX_SNIPPET;"
elif [ "$SNIPPET_CHANGED" = "0" ]; then
	say "redirects unchanged; no reload needed"
elif [ "$DO_RELOAD" = "1" ]; then
	systemctl reload nginx
	say "nginx reloaded"
else
	say "run: systemctl reload nginx"
fi

if [ "$DO_JSON" = "1" ]; then
	cat "$API_JSON"
fi
