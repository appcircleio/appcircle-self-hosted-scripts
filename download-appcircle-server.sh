#!/usr/bin/env bash
set -eou pipefail

credJsonPath="./cred.json"
gcloudAccessToken=""
userId=""
version="0.1.0"
preferedPackageVersion=""

version_info() {
  echo "Appcircle Server Package Downloader $version"
}

print_help() {
  printf '%s\n' "Download Appcircle Server package for your organization."
  printf '%s\n' "Usage: ./download-appcircle-server.sh"
  printf '%s\n\n' "You must have 'cred.json' in the current directory."
  printf '\t%s\n' "-h, --help: Prints help."
  printf '\t%s\n' "-v, --version: Prints script version."
}

parse_arguments() {
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
    --package-version)
      shift
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
    echo "'cred.json' file doesn't exist."
    echo "You need 'cred.json' to download Appcircle Server zip package."
    exit 1
  fi
}

extract_user_id() {
  credJsonEmail=$(grep -oP '"UUID": "\K[^"]+' <$credJsonPath)
  userId="$credJsonEmail"
}

authenticate_gcs() {
  credJsonPath=$1
  scope=$2
  jwtToken=$(create_jwt_google_cloud "$credJsonPath" "$scope")
  gcloudAccessToken=$(curl -s -X POST https://www.googleapis.com/oauth2/v4/token \
    --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer' \
    --data-urlencode "assertion=$jwtToken" |
    grep -oP '"access_token":"\K[^"]+')
}

download_appcircle_server_package() {
  if [[ -n "$preferedPackageVersion" ]]; then
    set +e
    foundedAppcircleServerPackage=$(echo "$listOfAppcirclePackages" | sort -rV | grep -m 1 "$preferedPackageVersion" )
    set -e
    if [[ -z "${foundedAppcircleServerPackage}" ]]; then
      echo "No Appcircle Server version found for the preferred version."
      exit 1
    fi
    echo  "Preferred Appcircle Server version: $foundedAppcircleServerPackage"
    appcircleServerPackage="$foundedAppcircleServerPackage"
  else
    latestAppcircleVersion=$(echo "$listOfAppcirclePackages" | tail -n 1)
    echo "Latest Appcircle Server version: $latestAppcircleVersion"
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
  privateKey=$(echo "$jsonData" | grep -oP '"private_key": "\K(.*)(?=")')
  saEmail=$(echo "$jsonData" | grep -oP '"client_email": "\K(.*)(?=")')

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
  echo "${request_body}.${signature}"
}

base64var() {
  printf "$1" | base64stream
}

base64stream() {
  base64 | tr '/+' '_-' | tr -d '=\n'
}

main() {
  parse_arguments "$@"
  echo "Downloading Appcircle Server zip package."
  check_cred_json
  extract_user_id
  authenticate_gcs "$credJsonPath" "https://www.googleapis.com/auth/devstorage.read_only"
  download_index_file
  download_appcircle_server_package
  echo "Appcircle Server Package has been downloaded."
  echo "You can now unzip the package"
}

main "$@"

