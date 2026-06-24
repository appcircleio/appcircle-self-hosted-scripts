#!/usr/bin/env bash
set -eou pipefail

credJsonPath="./cred.json"
gcloudAccessToken=""
userId=""
version="0.1.3"
preferedPackageVersion=""

# Google OAuth 2.0 token endpoints.
# The legacy endpoint is deprecated by Google but is still the host that existing
# self-hosted customers have allow-listed in their network policy. To stay
# backward compatible we try the legacy endpoint first and fall back to the
# current endpoint only when the legacy one cannot be reached.
legacyTokenUrl="https://www.googleapis.com/oauth2/v4/token"
currentTokenUrl="https://oauth2.googleapis.com/token"
# Holds the audience used for the JWT currently being signed. It must always
# match the token endpoint the assertion is sent to, otherwise Google rejects it.
tokenAud="$legacyTokenUrl"

version_info() {
  echo "Appcircle Server Package Downloader $version"
}

print_help() {
  printf '%s\n' "Download the Appcircle server package for your organization."
  printf '%s\n' "Usage: $0"
  printf '%s\n\n' "You must have 'cred.json' in the current directory."
  printf '\t%s\n' "-h, --help: Prints help."
  printf '\t%s\n' "-v, --version: Prints script version."
  printf '\t%s\n' "-p, --package-version: Specify an Appcircle server version."
}

check_env_variables() {
  preferedPackageVersion="${AC_SERVER_VERSION:-}"
}

suffix_version_option() {
  if [[ -n "${preferedPackageVersion}" ]]; then
    dotCount=$(echo "$preferedPackageVersion" | grep -o "\." | wc -l)
    if [[ "${dotCount}" -gt 1 ]]; then
      preferedPackageVersion="${preferedPackageVersion}-"
    fi
  fi
}

parse_arguments() {
  check_env_variables
  while (("$#")); do
    case "$1" in
    --help | -h)
      print_help
      exit 0
      ;;
    --version | -v)
      version_info
      exit 0
      ;;
    --package-version | -p)
      shift
      local packageVersion=${1:-}
      if [[ -z "$packageVersion" ]]; then
        echo "Please provide a package version."
        exit 1
      fi
      preferedPackageVersion="$1"
      ;;
    *)

      return 0
      ;;
    esac
    #shift
  done
}

print_deprecation_warning() {
  echo "WARNING: The Google OAuth token endpoint '$legacyTokenUrl' is deprecated by Google." >&2
  echo "         This script tries it first for backward compatibility and falls back to '$currentTokenUrl' when it cannot be reached." >&2
  echo "         Please make sure the host 'oauth2.googleapis.com' is allowed in your network/firewall policy." >&2
  echo "         For more information: https://docs.appcircle.io/self-hosted-appcircle/install-server/linux-package/configure-server/integrations-and-access/network-access#if-you-are-an-enterprise-licensed-or-poc-customer-appcircle-server-zip-package" >&2
}

check_cred_json() {
  if ! [[ -f $credJsonPath ]]; then
    echo "'cred.json' file doesn't exist in '$(pwd)'."
    echo "You need 'cred.json' to download the Appcircle server zip package."
    exit 1
  fi
}

extract_user_id() {
  set +e
  credJsonEmail=$(grep -oP '"UUID": "\K[^"]+' <$credJsonPath)
  if [[ -z "$credJsonEmail" ]]; then
    echo "'UUID' was not found in 'cred.json'. Please check your 'cred.json' file."
    exit 1
  fi
  set -e
  userId="$credJsonEmail"
}

authenticate_gcs() {
  credJsonPath=$1
  scope=$2

  gcloudAccessToken=""
  for tokenUrl in "$legacyTokenUrl" "$currentTokenUrl"; do
    # The JWT 'aud' claim must equal the token endpoint the assertion is posted
    # to, so the JWT is rebuilt and re-signed for each endpoint we try.
    tokenAud="$tokenUrl"
    create_jwt_google_cloud "$credJsonPath" "$scope"
    jwtToken="${jwtGoogleCloud}"

    set +e
    tokenResponse=$(curl -s --connect-timeout 30 -X POST "$tokenUrl" \
      --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer' \
      --data-urlencode "assertion=$jwtToken")
    curlStatus=$?
    set -e

    if [[ "$curlStatus" -ne 0 ]]; then
      echo "WARNING: Could not reach Google OAuth token endpoint '$tokenUrl' (curl exit $curlStatus). Trying the next endpoint if available." >&2
      continue
    fi

    set +e
    gcloudAccessToken=$(echo "$tokenResponse" | grep -oP '"access_token":"\K[^"]+')
    set -e
    if [[ -n "$gcloudAccessToken" ]]; then
      break
    fi
    echo "WARNING: Google OAuth token endpoint '$tokenUrl' did not return an access token. Trying the next endpoint if available." >&2
  done

  if [[ -z "$gcloudAccessToken" ]]; then
    echo "Failed to obtain a Google Cloud access token from both the legacy ('$legacyTokenUrl') and current ('$currentTokenUrl') OAuth endpoints."
    echo "Please verify your 'cred.json' and that one of these hosts is reachable from your network."
    exit 1
  fi
}

download_appcircle_server_package() {
  if [[ -n "$preferedPackageVersion" ]]; then
    set +e
    foundedAppcircleServerPackage=$(echo "$listOfAppcirclePackages" | tac | grep -m 1 "$preferedPackageVersion")
    set -e
    if [[ -z "${foundedAppcircleServerPackage}" ]]; then
      echo "No Appcircle server version was found for the preferred version."
      exit 1
    fi
    echo "Preferred version: $foundedAppcircleServerPackage"
    appcircleServerPackage="$foundedAppcircleServerPackage"
  else
    latestAppcircleVersion=$(echo "$listOfAppcirclePackages" | tail -n 1)
    echo "Latest version: $latestAppcircleVersion"
    appcircleServerPackage=$latestAppcircleVersion
  fi
  bucket="appcircle-self-hosted"
  objectDir="$userId%2F"
  listOfAppcirclePackages="$(curl -fL -o "$appcircleServerPackage" \
    -H "Authorization: Bearer $gcloudAccessToken" \
    "https://storage.googleapis.com/storage/v1/b/${bucket}/o/${objectDir}${appcircleServerPackage}?alt=media")"
}

download_index_file() {
  bucket="appcircle-self-hosted"
  objectDir="$userId%2F"
  indexFile="index.txt"
  listOfAppcirclePackages="$(curl -fsSL \
    -H "Authorization: Bearer $gcloudAccessToken" \
    "https://storage.googleapis.com/storage/v1/b/${bucket}/o/${objectDir}${indexFile}?alt=media")"
}

create_jwt_google_cloud() {
  validForSec="${3:-3600}"
  #private_key=$(jq -r .private_key "$dockerCredFile")
  jsonData=$(<"$credJsonPath")
  set +e
  privateKey=$(echo "$jsonData" | grep -oP '"private_key": "\K(.*)(?=")')
  saEmail=$(echo "$jsonData" | grep -oP '"client_email": "\K(.*)(?=")')
  if [[ -z "$privateKey" ]]; then
    echo "'private_key' was not found in 'cred.json'. Please check your 'cred.json' file."
    exit 1
  fi
  if [[ -z "$saEmail" ]]; then
    echo "'client_email' was not found in 'cred.json'. Please check your 'cred.json' file."
    exit 1
  fi
  set -e

  header='{"alg":"RS256","typ":"JWT"}'
  exp=$(($(date +%s) + "$validForSec"))
  iat=$(date +%s)

  claim=$(
    cat <<EOF
{
    "iss": "$saEmail",
    "scope": "$scope",
    "aud": "$tokenAud",
    "exp": $exp,
    "iat": $iat
}
EOF
  )
  request_body="$(base64var "$header").$(base64var "$claim")"
  signature=$(echo "$privateKey" | openssl dgst -sha256 -sign <(echo -e "$privateKey") <(echo -n "$request_body") | base64stream)
  jwtGoogleCloud="${request_body}.${signature}"
}

base64var() {
  printf "$1" | base64stream
}

base64stream() {
  base64 | tr '/+' '_-' | tr -d '=\n'
}

main() {
  parse_arguments "$@"
  suffix_version_option
  print_deprecation_warning
  echo "Downloading the Appcircle server zip package..."
  check_cred_json
  extract_user_id
  authenticate_gcs "$credJsonPath" "https://www.googleapis.com/auth/devstorage.read_only"
  download_index_file
  download_appcircle_server_package
  echo "Appcircle server package has been downloaded successfully."
  echo "You can now extract the package and follow the instructions in the setup documents."
}

main "$@"
