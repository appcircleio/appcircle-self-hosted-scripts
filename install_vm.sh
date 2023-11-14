#!/usr/bin/env bash
set -o pipefail
retryAttempt=1
retryInterval=30
retryMaxLimit=10

mkVmDir() {
  mkdir -p "$HOME/.tart/vms/$vmImageName"
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
    retryDownload
  fi
}

retryDownload() {
  if [[ "$retryAttempt" == "$retryMaxLimit" ]]; then
    echo "Failed to download the VM image. Please check your network"
    exit 1
  fi

  sleep $retryInterval
  curl -L -O -C - "https://storage.googleapis.com/appcircle-dev-common/self-hosted/$vmImageFile"

  if [[ "$?" != 0 ]] && [[ $retryAttempt -lt $retryMaxLimit ]]; then
    echo "Download failed. Re-trying: $retryAttempt"
    retryAttempt=$((retryAttempt + 1))
    retryDownload
  fi
}

extractVmFile() {
  echo "Extracting the vm file"
  tar -zxf macOS_230921.tar.gz --directory "$HOME/.tart/vms/macOS_230921"
}

checkMd5Sum() {
  validMd5=$(curl -s -I -L "https://storage.googleapis.com/appcircle-dev-common/self-hosted/$vmImageFile" | grep -i -w "etag" | cut -d '"' -f 2)
  echo "Valid: $validMd5"
  downloadedMd5=$(md5 "$vmImageFile" | cut -d' ' -f4)
  echo "Downloaded: $downloadedMd5"
  if [[ "$downloadedMd5" != "$validMd5" ]]; then
    echo "Your downloaded file is curropted. Delete the $vmImageFile and run the script again."
  fi
  echo "Your downloaded vm file is valid."
}

main() {
  vmImageName=$1
  if [[ -z $vmImageName ]]; then
    vmImageName=$(getTheLatestVmImageName)
  fi
  vmImageFile="$vmImageName.tar.gz"
  echo "Installing $vmImageName"
  downloadVmImage
  checkMd5Sum
  mkVmDir
  extractVmFile
}

main "$@"