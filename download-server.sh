#!/usr/bin/env bash
set -eou pipefail

credJsonPath="./cred.json"
gcloudAccessToken=""
userId=""
version="0.1.1"
preferedPackageVersion=""

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
  create_jwt_google_cloud "$credJsonPath" "$scope"
  jwtToken="${jwtGoogleCloud}"
  gcloudAccessToken=$(curl -s -X POST https://www.googleapis.com/oauth2/v4/token \
    --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer' \
    --data-urlencode "assertion=$jwtToken" |
    grep -oP '"access_token":"\K[^"]+')
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
    "aud": "https://www.googleapis.com/oauth2/v4/token",
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
