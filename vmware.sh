#!/usr/bin/env bash
# Download VMware Workstation Linux bundles from Internet Archive and GitHub.
# Requires Bash, curl, Python 3, and standard Unix tools. Does not install VMware.
set -euo pipefail
export LC_ALL=C

ARCHIVE_ITEM="vmwareworkstationarchive"
GITHUB_REPO="201853910/VMwareWorkstation"
DOWNLOAD_DIR="${HOME}/Downloads"
SOURCE="auto"
VERSION=""
MODE=""
PRINT_URL=false
TMP_DIR=""
LOCK_DIR=""

usage() {
    cat <<'EOF'
Usage: download_workstation.sh [options]

With no selection option, show an interactive version menu.
  -l, --list             List available Linux bundles, newest first
      --latest           Download the newest listed release
  -v, --version VERSION  Download an exact release (17.5.1, 25H2, 26H1u1)
  -s, --source SOURCE    auto (default), archive.org, or github
  -d, --directory DIR    Destination directory (default: ~/Downloads)
      --url              Print the preferred URL without downloading
      --item IDENTIFIER  Use another Internet Archive collection
      --repo OWNER/REPO  Use another GitHub release repository
  -h, --help             Show this help

Examples:
  bash download_workstation.sh --latest
  bash download_workstation.sh -v 17.5.1
  bash download_workstation.sh --list

Auto mode merges both catalogs, prefers Archive.org for duplicate builds,
and can retry the same build from GitHub after an archive download failure.
Downloads use one transfer at a time and can resume on the next run.
Archive checksums and GitHub SHA-256 digests are verified when supplied.
Older GitHub assets without a digest can only be checked by file size.
Checks verify agreement with the mirror, not publisher authenticity.
Verified bundles are made executable but are never run automatically.
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*" >&2; }
cleanup() {
    if [[ -n "$LOCK_DIR" ]]; then rmdir "$LOCK_DIR" 2>/dev/null || true; fi
    if [[ -n "$TMP_DIR" ]]; then rm -rf "$TMP_DIR"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
set_mode() {
    [[ -z "$MODE" ]] || die 'Use only one of --list, --latest, or --version.'
    MODE="$1"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -l|--list) set_mode list; shift ;;
        --latest) set_mode latest; shift ;;
        -v|--version|-s|--source|-d|--directory|--item|--repo)
            [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die "$1 requires a value."
            case "$1" in
                -v|--version) set_mode version; VERSION="$2" ;;
                -s|--source) SOURCE="$2" ;;
                -d|--directory) DOWNLOAD_DIR="$2" ;;
                --item) ARCHIVE_ITEM="$2" ;;
                --repo) GITHUB_REPO="$2" ;;
            esac
            shift 2 ;;
        --url) PRINT_URL=true; shift ;;
        -k) die 'The retired compression option was removed. All downloads are .bundle files.' ;;
        *) die "Unknown argument: $1. Use --help for usage." ;;
    esac
done
case "$SOURCE" in auto|archive.org|github) ;; *) die 'Source must be auto, archive.org, or github.' ;; esac
[[ "$ARCHIVE_ITEM" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid archive identifier.'
[[ "$GITHUB_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 'Repository must be OWNER/REPO.'
[[ "$MODE" != list || "$PRINT_URL" == false ]] || die '--url requires a version selection, not --list.'
if [[ -n "$VERSION" ]]; then
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || "$VERSION" =~ ^[0-9]{2}[Hh][12]([Uu][0-9]+)?$ ]] ||
        die 'Use a version such as 17.5.1, 25H2, or 26H1u1.'
fi
for tool in curl python3 mktemp mkdir rmdir rm ln chmod wc sleep tr; do
    command -v "$tool" >/dev/null 2>&1 || die "Required tool not found: $tool"
done
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/workstation-download.XXXXXXXX")
log 'Fetching Linux installer catalogs...'

python3 - "$TMP_DIR" "$SOURCE" "$ARCHIVE_ITEM" "$GITHUB_REPO" <<'PY' || die 'Could not build the installer catalog.'
import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote, unquote, urlsplit

directory, source, item, repo = sys.argv[1:]
pattern = re.compile(r'^VMware-Workstation-Full-(\d+\.\d+\.\d+|\d{2}H[12](?:u\d+)?)-(\d+)\.x86_64\.bundle$', re.I)
rows = []

def fetch(url):
    result = subprocess.run([
        'curl', '-q', '--fail', '--silent', '--show-error', '--location',
        '--proto', '=https', '--proto-redir', '=https', '--connect-timeout', '20',
        '--max-time', '120', '--retry', '2', '--retry-delay', '2', url,
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise ValueError(result.stderr.decode('utf-8', 'replace').strip())
    return json.loads(result.stdout)

def record(name, size, origin, url, algorithm, digest):
    match = pattern.fullmatch(name)
    if not match:
        return None
    if not re.fullmatch(r'[1-9]\d*', str(size)) or int(size) >= 2**63:
        raise ValueError('Invalid file size for ' + name)
    version = match[1].upper().replace('U', 'u')
    calendar = re.fullmatch(r'(\d{2})H([12])(?:u(\d+))?', version)
    key = ((1, int(calendar[1]), int(calendar[2]), int(calendar[3] or 0)) if calendar
           else (0, *map(int, version.split('.')))) + (int(match[2]),)
    filename = 'VMware-Workstation-Full-{}-{}.x86_64.bundle'.format(version, match[2])
    return {'key': key, 'version': version, 'build': match[2], 'name': filename,
            'size': str(size), 'source': origin, 'url': url, 'algorithm': algorithm, 'digest': digest}

if source in ('auto', 'archive.org'):
    try:
        data = fetch('https://archive.org/metadata/' + item)
        if not isinstance(data, dict) or not isinstance(data.get('files'), list):
            raise ValueError('Archive response has no file list.')
        pending = []
        for file in data['files']:
            if not isinstance(file, dict) or not isinstance(file.get('name'), str):
                continue
            parts = file['name'].split('/')
            if len(parts) < 2 or parts[0] != 'Linux' or not pattern.fullmatch(parts[-1]):
                continue
            if any(not p or p in ('.', '..') or re.search(r'[\x00-\x1f\x7f]', p) for p in parts):
                continue
            if file.get('private') and str(file['private']).lower() != 'false':
                continue
            digest = str(file.get('sha1', '')).lower()
            if not re.fullmatch(r'[a-f0-9]{40}', digest):
                raise ValueError('Missing or invalid archive SHA-1 for ' + parts[-1])
            url = 'https://archive.org/download/' + item + '/' + '/'.join(quote(p, safe='') for p in parts)
            pending.append(record(parts[-1], file.get('size'), 'archive.org', url, 'sha1', digest))
        rows.extend(pending)
    except (ValueError, TypeError, KeyError, AttributeError) as error:
        print('Notice: Archive.org catalog unavailable: ' + str(error), file=sys.stderr)

if source in ('auto', 'github'):
    try:
        pending = []
        page = 1
        while True:
            releases = fetch('https://api.github.com/repos/{}/releases?per_page=100&page={}'.format(repo, page))
            if not isinstance(releases, list):
                raise ValueError('GitHub response is not a release list.')
            for release in releases:
                if release.get('draft') or release.get('prerelease'):
                    continue
                for asset in release.get('assets', []):
                    name = asset.get('name', '')
                    if not isinstance(name, str) or not pattern.fullmatch(name) or asset.get('state', 'uploaded') != 'uploaded':
                        continue
                    url = asset.get('browser_download_url', '')
                    parsed = urlsplit(url)
                    prefix = '/' + repo + '/releases/download/'
                    if parsed.scheme != 'https' or parsed.netloc != 'github.com' or not parsed.path.startswith(prefix):
                        continue
                    if parsed.query or parsed.fragment or unquote(parsed.path.rsplit('/', 1)[-1]) != name:
                        continue
                    if re.search(r'[\x00-\x20\x7f]', url):
                        continue
                    digest = asset.get('digest')
                    if digest is None:
                        algorithm, checksum = 'size', '-'
                    elif isinstance(digest, str) and re.fullmatch(r'sha256:[a-fA-F0-9]{64}', digest):
                        algorithm, checksum = 'sha256', digest.split(':')[1].lower()
                    else:
                        raise ValueError('Invalid GitHub digest for ' + name)
                    pending.append(record(name, asset.get('size'), 'github', url, algorithm, checksum))
            if len(releases) < 100:
                break
            page += 1
        rows.extend(pending)
    except (ValueError, TypeError, KeyError, AttributeError) as error:
        print('Notice: GitHub catalog unavailable: ' + str(error), file=sys.stderr)

rows.sort(key=lambda r: (r['key'], r['source'] == 'archive.org'), reverse=True)
groups = {}
seen = set()
for row in rows:
    if row['url'] in seen:
        continue
    seen.add(row['url'])
    groups.setdefault((row['version'], row['build']), []).append(row)
with Path(directory, 'catalog.tsv').open('w') as catalog, Path(directory, 'choices.tsv').open('w') as choices:
    for group in groups.values():
        first = group[0]
        sources = ','.join(r['source'] for r in group)
        checks = ','.join(dict.fromkeys(r['algorithm'] for r in group))
        choices.write('\t'.join([first['version'], first['build'], first['name'], first['size'], sources, checks]) + '\n')
        for row in group:
            catalog.write('\t'.join([row['version'], row['build'], row['source'], row['size'], row['algorithm'], row['digest'], row['url']]) + '\n')
PY

VERSIONS=(); BUILDS=(); FILENAMES=(); SIZES=(); SOURCES=(); CHECKS=()
while IFS=$'\t' read -r version build filename size sources checks; do
    [[ -n "$version" ]] || continue
    VERSIONS+=("$version"); BUILDS+=("$build"); FILENAMES+=("$filename")
    SIZES+=("$size"); SOURCES+=("$sources"); CHECKS+=("$checks")
done < "$TMP_DIR/choices.tsv"
[[ ${#VERSIONS[@]} -gt 0 ]] || die 'No supported Linux bundles found in the selected sources.'

show_versions() {
    local i
    printf '%4s  %-10s %-10s %-20s %s\n' '#' VERSION BUILD SOURCES CHECK
    for ((i=0; i<${#VERSIONS[@]}; i++)); do
        printf '%4d  %-10s %-10s %-20s %s\n' "$((i+1))" "${VERSIONS[$i]}" "${BUILDS[$i]}" "${SOURCES[$i]}" "${CHECKS[$i]}"
    done
}
if [[ "$MODE" == list ]]; then show_versions; exit 0; fi
SELECTED=-1
if [[ "$MODE" == latest ]]; then
    SELECTED=0
elif [[ "$MODE" == version ]]; then
    NORMALIZED_VERSION=$(printf '%s' "$VERSION" | tr '[:upper:]' '[:lower:]')
    for ((i=0; i<${#VERSIONS[@]}; i++)); do
        if [[ "$(printf '%s' "${VERSIONS[$i]}" | tr '[:upper:]' '[:lower:]')" == "$NORMALIZED_VERSION" ]]; then
            SELECTED=$i; break
        fi
    done
    [[ "$SELECTED" -ge 0 ]] || die "Version $VERSION is unavailable. Use --list to see available releases."
else
    [[ -t 0 ]] || die 'Use --latest, --version, or --list when running noninteractively.'
    show_versions >&2
    while true; do
        printf 'Choose an installer number (or q to quit): ' >&2
        read -r choice || exit 0
        [[ "$choice" != q && "$choice" != Q ]] || exit 0
        if [[ "$choice" =~ ^[0-9]{1,6}$ ]]; then
            choice=$((10#$choice))
            if [[ "$choice" -ge 1 && "$choice" -le ${#VERSIONS[@]} ]]; then
                SELECTED=$((choice-1)); break
            fi
        fi
        log 'Choose a number from the list.'
    done
fi
VERSION="${VERSIONS[$SELECTED]}"
BUILD="${BUILDS[$SELECTED]}"
if $PRINT_URL; then
    while IFS=$'\t' read -r version build source size algorithm digest url; do
        if [[ "$version" == "$VERSION" && "$build" == "$BUILD" ]]; then printf '%s\n' "$url"; exit 0; fi
    done < "$TMP_DIR/catalog.tsv"
fi
log "Selected Workstation $VERSION (build $BUILD, Linux x86_64)."
log 'Source checks establish agreement with third-party mirrors only.'
mkdir -p "$DOWNLOAD_DIR"
DOWNLOAD_DIR=$(cd "$DOWNLOAD_DIR" && pwd -P)
OUTPUT="$DOWNLOAD_DIR/${FILENAMES[$SELECTED]}"
if ! mkdir "$OUTPUT.lock" 2>/dev/null; then
    die "Another download may be running. If none is running, remove $OUTPUT.lock and retry."
fi
LOCK_DIR="$OUTPUT.lock"
[[ ! -L "$OUTPUT" ]] || die "Refusing a symbolic link: $OUTPUT"
[[ ! -e "$OUTPUT" || -f "$OUTPUT" ]] || die "Destination is not a regular file: $OUTPUT"

verify_file() {
    python3 - "$1" "$SIZE" "$ALGORITHM" "$DIGEST" <<'PY'
import hashlib
import os
import sys
path, size, algorithm, expected = sys.argv[1:]
try:
    if os.path.getsize(path) != int(size):
        sys.exit(1)
    if algorithm != 'size':
        digest = hashlib.new(algorithm)
        with open(path, 'rb') as file:
            for chunk in iter(lambda: file.read(1024 * 1024), b''):
                digest.update(chunk)
        if digest.hexdigest() != expected:
            sys.exit(1)
except OSError:
    sys.exit(1)
PY
}

finish() {
    if [[ "$ALGORITHM" == size ]]; then
        log 'File size matches GitHub metadata. This older asset has no published checksum.'
    else
        log "File size and $ALGORITHM match $CANDIDATE metadata."
    fi
    chmod +x "$OUTPUT" || die "Could not make the bundle executable. Download kept at: $OUTPUT"
    log 'Bundle ready. Run it manually when you want to install VMware.'
    printf '%s\n' "$OUTPUT"
}

try_download() {
    local bytes attempt status
    if [[ -L "$PARTIAL" || ( -e "$PARTIAL" && ! -f "$PARTIAL" ) ]]; then
        log "Refusing a non-regular partial file: $PARTIAL"; return 1
    fi
    bytes=0
    if [[ -f "$PARTIAL" ]]; then bytes=$(wc -c < "$PARTIAL") || return 1; fi
    if [[ "$bytes" -gt "$SIZE" ]]; then log "Partial file is too large; move it aside: $PARTIAL"; return 1; fi
    if [[ "$bytes" -lt "$SIZE" ]]; then
        for attempt in 1 2 3; do
            log "Downloading from $CANDIDATE (attempt $attempt of 3)..."
            if curl -q --fail --show-error --location --progress-bar \
                --proto '=https' --proto-redir '=https' --connect-timeout 20 \
                --speed-limit 1024 --speed-time 120 --continue-at - --output "$PARTIAL" "$URL"; then
                break
            else
                status=$?
                if [[ "$status" == 33 ]]; then log "Server refused resumption; move this partial aside: $PARTIAL"; return 1; fi
                if [[ "$attempt" == 3 ]]; then log "Download failed; partial kept at: $PARTIAL"; return 1; fi
                sleep 3
            fi
        done
    fi
    log "Checking $CANDIDATE download..."
    if ! verify_file "$PARTIAL"; then
        log "Download failed verification; removing corrupt partial: $PARTIAL"
        rm -f "$PARTIAL" || return 1
        return 1
    fi
    ln "$PARTIAL" "$OUTPUT" || return 1
    rm -f "$PARTIAL" || return 1
}

while IFS=$'\t' read -r version build CANDIDATE SIZE ALGORITHM DIGEST URL; do
    [[ "$version" == "$VERSION" && "$build" == "$BUILD" ]] || continue
    if [[ -f "$OUTPUT" ]]; then
        if verify_file "$OUTPUT"; then finish; exit 0; fi
        continue
    fi
    PARTIAL="$OUTPUT.$CANDIDATE.part"
    if [[ "$ALGORITHM" == size ]]; then log 'Notice: This older GitHub asset has no checksum; only its size can be verified.'; fi
    if try_download; then finish; exit 0; fi
    log 'Trying another listed source for this exact version and build, if available.'
done < "$TMP_DIR/catalog.tsv"
if [[ -f "$OUTPUT" ]]; then
    die "Existing file does not match available metadata. Move it aside before retrying: $OUTPUT"
fi
die 'Could not download and verify the selected build from any listed source. Retry later or choose another source.'