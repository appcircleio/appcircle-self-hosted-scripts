#!/usr/bin/env bash

source ./tests/shunit2-setup.sh

# The functions are sourced, so these tests need no cred.json and no network.
source ./download-server.sh
set +eu +o pipefail

oneTimeSetUp() {
  workDir="$(mktemp -d)"
  mkdir -p "$workDir/empty"
  openssl genrsa -out "$workDir/key.pem" 2048 2>/dev/null
  openssl rsa -in "$workDir/key.pem" -pubout -out "$workDir/pub.pem" 2>/dev/null
  # The private key is stored in cred.json as one JSON string with \n escapes.
  escapedKey="$(awk '{ printf "%s\\n", $0 }' "$workDir/key.pem")"
  cat >"$workDir/cred.json" <<EOF
{
  "type": "service_account",
  "UUID": "11111111-2222-3333-4444-555555555555",
  "private_key": "$escapedKey",
  "client_email": "self-hosted-test@example.iam.gserviceaccount.com"
}
EOF
}

oneTimeTearDown() {
  [[ "${_shunit_name_}" = 'EXIT' ]] && return 0
  rm -rf "$workDir"
}

testUserIdFromCredJson() {
  credJsonPath="$workDir/cred.json"
  extract_user_id
  assertEquals "11111111-2222-3333-4444-555555555555" "$userId"
}

testClientEmailFromCredJson() {
  assertEquals "self-hosted-test@example.iam.gserviceaccount.com" "$(json_string_value client_email <"$workDir/cred.json")"
}

testAccessTokenFromTokenResponse() {
  assertEquals "ya29.compact" "$(echo '{"access_token":"ya29.compact","expires_in":3599,"token_type":"Bearer"}' | json_string_value access_token)"
  assertEquals "ya29.spaced" "$(printf '{\n  "access_token" : "ya29.spaced",\n  "expires_in": 3599\n}\n' | json_string_value access_token)"
  assertEquals "" "$(echo '{"error":"invalid_grant"}' | json_string_value access_token)"
}

testReverseLines() {
  assertEquals "c b a " "$(printf 'a\nb\nc\n' | reverse_lines | tr '\n' ' ')"
}

# Prints the package download_appcircle_server_package picks for version $1
# ("" for the latest), or nothing when it finds none. curl is stubbed, so
# nothing is downloaded; the subshell keeps its exit and set -e out of shunit2.
selected_package() {
  (
    curl() { :; }
    # index.txt lists the packages oldest first, with or without a build suffix.
    listOfAppcirclePackages="$(printf '%s\n' \
      appcircle-server-linux-x64-3.33.0.zip \
      appcircle-server-linux-x64-3.34.1-aaa1111-10.zip \
      appcircle-server-linux-x64-3.34.1-bbb2222-11.zip \
      appcircle-server-linux-x64-3.34.10-ccc3333-12.zip \
      appcircle-server-linux-x64-3.35.1.zip \
      appcircle-server-linux-x64-3.35.10.zip)"
    preferedPackageVersion="$1"
    suffix_version_option
    download_appcircle_server_package >/dev/null 2>&1
    echo "$appcircleServerPackage"
  )
}

testExactVersionWithBuildSuffix() {
  # The newest 3.34.1 build wins, and 3.34.1 never matches 3.34.10.
  assertEquals "appcircle-server-linux-x64-3.34.1-bbb2222-11.zip" "$(selected_package 3.34.1)"
}

testExactVersionWithoutBuildSuffix() {
  assertEquals "appcircle-server-linux-x64-3.33.0.zip" "$(selected_package 3.33.0)"
  assertEquals "appcircle-server-linux-x64-3.35.1.zip" "$(selected_package 3.35.1)"
  assertEquals "appcircle-server-linux-x64-3.35.10.zip" "$(selected_package 3.35.10)"
}

testVersionPrefix() {
  assertEquals "appcircle-server-linux-x64-3.34.10-ccc3333-12.zip" "$(selected_package 3.34)"
  assertEquals "appcircle-server-linux-x64-3.35.10.zip" "$(selected_package 3.35)"
}

testLatestVersion() {
  assertEquals "appcircle-server-linux-x64-3.35.10.zip" "$(selected_package "")"
}

testVersionNotFound() {
  assertEquals "" "$(selected_package 3.34.2)"
  assertEquals "" "$(selected_package 3.36)"
}

testJwtSignatureVerifies() {
  credJsonPath="$workDir/cred.json"
  scope="https://www.googleapis.com/auth/devstorage.read_only"
  tokenAud="https://oauth2.googleapis.com/token"
  create_jwt_google_cloud "$credJsonPath" "$scope"
  signedPart="${jwtGoogleCloud%.*}"
  signature="${jwtGoogleCloud##*.}"
  # Back from base64url without padding to base64 with padding.
  signature="$(echo "$signature" | tr '_-' '/+')"
  while [ $((${#signature} % 4)) -ne 0 ]; do signature="${signature}="; done
  echo "$signature" | openssl base64 -d -A >"$workDir/sig.bin"
  printf '%s' "$signedPart" >"$workDir/signed.txt"
  assertTrue "The JWT signature should verify with the public key." \
    "openssl dgst -sha256 -verify '$workDir/pub.pem' -signature '$workDir/sig.bin' '$workDir/signed.txt'"
}

testRunsWhenPiped() {
  # The docs run the script with curl ... | bash; it must reach main and stop at the missing cred.json.
  output="$(cd "$workDir/empty" && bash <"$OLDPWD/download-server.sh" 2>&1)"
  assertContains "Piped into bash, the script should run main." "$output" "'cred.json' file doesn't exist"
}

testNoGnuOnlyTools() {
  code="$(grep -v '^[[:space:]]*#' ./download-server.sh)"
  assertEquals "grep -P is not available on macOS." "0" "$(echo "$code" | grep -c 'grep -[a-zA-Z]*P')"
  assertEquals "tac is not available on macOS." "0" "$(echo "$code" | grep -c '| tac')"
}

source shunit2
