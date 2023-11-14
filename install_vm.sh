#!/usr/bin/env bash
set -o pipefail
retryAttempt=1
retryInterval=30
retryMaxLimit=10
version=v1.0.0

mkVmDir() {
  mkdir -p "$HOME/.tart/vms/$vmImageName"
}

printVersion() {
  echo "${version}"
}

printHelp() {
  printf '%s\n' "Install, validate, extract macOS vm."
  printf '%s\n' "By default, latest macOS vm image will be installed."
  printf 'Usage: %s [macOS-vm-name] [-h|--help]\n' "$0"
  printf '\t%s\n' "macOS-vm-name: Specify the macOS vm name optionally."
  printf '\t%s\n' "-h, --help: Prints help"
}

parseArguments() {
  args=("$@")
  for arg in "${args[@]}"; do
    if [[ $arg == "--help" || $arg == "-h" ]]; then
      printHelp
      exit 0
    elif [[ $arg == "--version" || $arg == "-v" ]]; then
      printVersion
      exit 0
    fi
  done

  vmImageName=$1
  if [[ -z $vmImageName ]]; then
    vmImageName=$(getTheLatestVmImageName)
  fi
  vmImageFile="$vmImageName.tar.gz"
}

getTheLatestVmImageName() {
  runnerList=$(curl -fsSL -X GET "https://storage.googleapis.com/storage/v1/b/appcircle-dev-common/o?matchGlob=self-hosted/macOS*")
  latestRunner=$(echo "$runnerList" | grep -o '"name": "[^"]*' | tail -n 1)
  vmFile=$(basename "$latestRunner")
  echo "${vmFile%.tar.gz}"
}

downloadVmImage() {
  echo "Downloading the vm file"
  curl -L -O -C - "https://storage.googleapis.com/appcircle-dev-common/self-hosted/$vmImageFile"
  if [[ "$?" != 0 ]]; then
    if [[ "$retryAttempt" -gt "$retryMaxLimit" ]]; then
      retryAttempt=$((retryAttempt - 1))
      echo "Failed to download the VM image in $retryAttempt attempt. Please check your network"
      exit 1
    fi
    echo "Download failed. Re-trying: $retryAttempt"
    retryAttempt=$((retryAttempt + 1))
    sleep $retryInterval
    downloadVmImage
  fi
}

extractVmFile() {
  echo "Extracting the vm file"
  tar -zxf macOS_230921.tar.gz --directory "$HOME/.tart/vms/macOS_230921"
}

checkMd5Sum() {
  validMd5=$(curl -fsSL -I "https://storage.googleapis.com/appcircle-dev-common/self-hosted/$vmImageFile" | grep -i -w "etag" | cut -d '"' -f 2)
  echo "Valid: $validMd5"
  downloadedMd5=$(md5 "$vmImageFile" | cut -d' ' -f4)
  echo "Downloaded: $downloadedMd5"
  if [[ "$downloadedMd5" != "$validMd5" ]]; then
    echo "Your downloaded file is curropted. Delete the $vmImageFile and run the script again."
    exit 1
  fi
  echo "Your downloaded vm file is valid."
}

main() {
  parseArguments "$@"
  echo "Installing $vmImageName"
  downloadVmImage
  checkMd5Sum
  mkVmDir
  extractVmFile
}

main "$@"
