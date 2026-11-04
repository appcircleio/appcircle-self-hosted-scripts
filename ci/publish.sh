#!/usr/bin/env bash
# Publishes the scripts listed in ci/publish.map to the self-hosted bucket. Run from the repository root.
#
#   ci/publish.sh build    Copy each file under its published name into dist/ and write <name>.md5 next to it.
#   ci/publish.sh upload   Upload dist/ to the bucket. A versioned name that already exists with different
#                          content fails the run; files that are already up to date are skipped.
#   ci/publish.sh verify   Download every published name and its .md5 from the public origin and compare.
#
# Environment: BUCKET_PATH (gs://...), ORIGIN_URL (https://storage.googleapis.com/...), CACHE_BUST (any
# unique string, appended as a query parameter so the verify step does not read a cached copy).

set -euo pipefail

mapFile="ci/publish.map"
distDir="dist"
mutableCacheControl="public, max-age=300"
versionedCacheControl="public, max-age=3600"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

# Prints "<source> <published name> <versioned: 0|1>" per mapping line.
readMap() {
  local source target version
  while read -r source target; do
    [[ -z "$source" || "$source" == \#* ]] && continue
    [[ -f "$source" ]] || fail "$mapFile names $source, which does not exist."
    if [[ "$target" == *"{VERSION}"* ]]; then
      version=$(sed -n -E 's/^VERSION="?([^"]+)"?[[:space:]]*$/\1/p' "$source" | head -n 1)
      [[ -n "$version" ]] || fail "$source has no VERSION= line, so $target cannot be named."
      echo "$source ${target//\{VERSION\}/$version} 1"
    else
      echo "$source $target 0"
    fi
  done <"$mapFile"
}

md5Of() {
  md5sum "$1" | cut -d ' ' -f 1
}

build() {
  local source target versioned
  rm -rf "$distDir"
  mkdir -p "$distDir"
  while read -r source target versioned; do
    cp "$source" "$distDir/$target"
    (cd "$distDir" && md5sum "$target" >"$target.md5")
    echo "$source -> $target $(md5Of "$distDir/$target")"
  done < <(readMap)
}

# Prints the MD5 of the object, an empty line if it does not exist, and fails on any other error.
remoteMd5() {
  local object="$1" tmpDir status=0
  tmpDir=$(mktemp -d)
  if gcloud storage cp "$object" "$tmpDir/object" 2>"$tmpDir/error"; then
    md5Of "$tmpDir/object"
  elif grep -qiE 'not found|no urls matched|404' "$tmpDir/error"; then
    echo ""
  else
    cat "$tmpDir/error" >&2
    status=1
  fi
  rm -rf "$tmpDir"
  return "$status"
}

upload() {
  local source target versioned localMd5 currentMd5 cacheControl
  [[ -d "$distDir" ]] || fail "Run '$0 build' first."
  while read -r source target versioned; do
    localMd5=$(md5Of "$distDir/$target")
    currentMd5=$(remoteMd5 "$BUCKET_PATH/$target") || fail "Cannot read $BUCKET_PATH/$target."
    if [[ "$currentMd5" == "$localMd5" ]]; then
      echo "Up to date: $target ($localMd5)"
      continue
    fi
    if [[ "$versioned" == 1 && -n "$currentMd5" ]]; then
      fail "$target already exists with MD5 $currentMd5, not $localMd5. Versioned files are immutable: bump VERSION in $source."
    fi
    cacheControl="$mutableCacheControl"
    [[ "$versioned" == 1 ]] && cacheControl="$versionedCacheControl"
    gcloud storage cp --content-type=text/x-sh --cache-control="$cacheControl" \
      "$distDir/$target" "$BUCKET_PATH/$target"
    gcloud storage cp --content-type=text/plain --cache-control="$cacheControl" \
      "$distDir/$target.md5" "$BUCKET_PATH/$target.md5"
    echo "Published: $target ($localMd5) -> ${PUBLIC_URL:-$BUCKET_PATH}/$target"
  done < <(readMap)
}

verify() {
  local source target versioned localMd5 servedMd5 checksumFile failed=0
  while read -r source target versioned; do
    localMd5=$(md5Of "$source")
    if ! servedMd5=$(curl -fsSL "$ORIGIN_URL/$target?cb=$CACHE_BUST" | md5sum | cut -d ' ' -f 1) ||
      [[ "$servedMd5" != "$localMd5" ]]; then
      echo "MISMATCH: $ORIGIN_URL/$target serves $servedMd5, the repository has $localMd5." >&2
      failed=1
      continue
    fi
    checksumFile=$(curl -fsSL "$ORIGIN_URL/$target.md5?cb=$CACHE_BUST" | awk 'NR == 1 { print tolower($1) }') || true
    if [[ "$checksumFile" != "$localMd5" ]]; then
      echo "MISMATCH: $ORIGIN_URL/$target.md5 contains '$checksumFile', expected $localMd5." >&2
      failed=1
      continue
    fi
    echo "OK: $target $localMd5"
  done < <(readMap)

  # Run the scripts the way the docs do (curl ... | bash) to catch failures the tests miss (PL-587).
  curl -fsSL "$ORIGIN_URL/download-server.sh?cb=$CACHE_BUST" | bash -s -- --version || failed=1
  curl -fsSL "$ORIGIN_URL/download-runner.sh?cb=$CACHE_BUST" | bash -s -- --version || failed=1

  [[ "$failed" == 0 ]] || fail "Verification failed."
}

case "${1:-}" in
build) build ;;
upload) upload ;;
verify) verify ;;
*) fail "Usage: $0 build|upload|verify" ;;
esac
