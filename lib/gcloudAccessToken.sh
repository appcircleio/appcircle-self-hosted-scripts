#!/usr/bin/env bash
set -eou pipefail

credJsonPath=$1
scope=$2

main() {
  jwtToken=$(createJWTGoogleCloud "$credJsonPath" "$scope")
  curl -s -X POST https://www.googleapis.com/oauth2/v4/token \
    --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer' \
    --data-urlencode "assertion=$jwtToken" |
    grep -oP '"access_token":"\K[^"]+'
}

base64var() {
  printf "$1" | base64stream
}

base64stream() {
  base64 | tr '/+' '_-' | tr -d '=\n'
}

createJWTGoogleCloud() {
  valid_for_sec="${3:-3600}"
  #private_key=$(jq -r .private_key "$dockerCredFile")
  json_data=$(<"$credJsonPath")
  private_key=$(echo "$json_data" | grep -oP '"private_key": "\K(.*)(?=")')
  sa_email=$(echo "$json_data" | grep -oP '"client_email": "\K(.*)(?=")')

  header='{"alg":"RS256","typ":"JWT"}'
  exp=$(($(date +%s) + "$valid_for_sec"))
  iat=$(date +%s)

  claim=$(
    cat <<EOF
{
    "iss": "$sa_email",
    "scope": "$scope",
    "aud": "https://www.googleapis.com/oauth2/v4/token",
    "exp": $exp,
    "iat": $iat
}
EOF
  )
  request_body="$(base64var "$header").$(base64var "$claim")"
  signature=$(echo "$private_key" | openssl dgst -sha256 -sign <(echo -e "$private_key") <(echo -n "$request_body") | base64stream)
  printf "$request_body.$signature"
}

main
