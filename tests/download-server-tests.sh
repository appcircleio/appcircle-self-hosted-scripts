#!/usr/bin/env bash

source ./tests/shunit2-setup.sh

# The functions are sourced, so these tests need no cred.json and no network.
source ./download-server.sh
set +eu +o pipefail

oneTimeSetUp() {
  workDir="$(mktemp -d)"
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

testPreferredVersionSelection() {
  # index.txt lists the customer packages oldest first, with a build suffix.
  packages="$(printf '%s\n' appcircle-server-linux-x64-3.34.1-aaa1111-10.zip appcircle-server-linux-x64-3.34.1-bbb2222-11.zip appcircle-server-linux-x64-3.34.10-ccc3333-12.zip)"
  preferedPackageVersion="3.34.1"
  suffix_version_option
  assertEquals "3.34.1-" "$preferedPackageVersion"
  # The "-" suffix keeps 3.34.1 from matching 3.34.10; the newest 3.34.1 build wins.
  assertEquals "appcircle-server-linux-x64-3.34.1-bbb2222-11.zip" "$(echo "$packages" | reverse_lines | grep -m 1 "$preferedPackageVersion")"
  preferedPackageVersion="3.34"
  suffix_version_option
  assertEquals "appcircle-server-linux-x64-3.34.10-ccc3333-12.zip" "$(echo "$packages" | reverse_lines | grep -m 1 "$preferedPackageVersion")"
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

testNoGnuOnlyTools() {
  code="$(grep -v '^[[:space:]]*#' ./download-server.sh)"
  assertEquals "grep -P is not available on macOS." "0" "$(echo "$code" | grep -c 'grep -[a-zA-Z]*P')"
  assertEquals "tac is not available on macOS." "0" "$(echo "$code" | grep -c '| tac')"
}

source shunit2
