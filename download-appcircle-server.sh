#!/usr/bin/env bash
set -eou pipefail

credJsonPath="./cred.json"
gloucdAuthenticatorPath="./lib/gcloudAccessToken.sh"
gcloudAccessToken=""
userId=""
version="0.1.0"

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
  echo "credJsonEmail: $credJsonEmail"
  userId="$credJsonEmail"
}

authenticate_gcs() {
  gcloudAccessToken=$($gloucdAuthenticatorPath "$credJsonPath" "https://www.googleapis.com/auth/devstorage.read_only")
}

download_appcircle_server_package() {
  latestAppcircleVersion=$(echo "$listOfAppcirclePackages" | tail -n 1)
  bucket="appcircle-self-hosted"
  objectDir="$userId%2F"
  appcircleServerPackage=$latestAppcircleVersion
  listOfAppcirclePackages="$(curl -X GET -fL -o $appcircleServerPackage -C - \
    -H "Authorization: Bearer $gcloudAccessToken" \
    "https://storage.googleapis.com/storage/v1/b/${bucket}/o/${objectDir}${appcircleServerPackage}?alt=media")"
}

download_index_file() {
  bucket="appcircle-self-hosted"
  objectDir="0834c312-ea91-4e47-ba91-2a1b3c07f759%2F"
  indexFile="index.txt"
  listOfAppcirclePackages="$(curl -X GET -fsSL -C - \
    -H "Authorization: Bearer $gcloudAccessToken" \
    "https://storage.googleapis.com/storage/v1/b/${bucket}/o/${objectDir}${indexFile}?alt=media")"
}

main() {
  parse_arguments "$@"
  echo "Downloading Appcircle Server zip package."
  check_cred_json
  extract_user_id
  authenticate_gcs
  download_index_file
  download_appcircle_server_package
}

main "$@"
