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
  printf '%s\n' "Install, validate, extract macOS VM."
  printf '%s\n' "By default, latest macOS VM image will be installed."
  printf 'Usage: %s [macOS-vm-name] [-h|--help]\n' "$0"
  printf '\t%s\n' "macOS-vm-name: Specify the macOS VM name optionally."
  printf '\t%s\n' "-h, --help: Prints help."
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

  if [[ "$#" -ne 0 ]] && [[ "$#" -ne 1 ]]; then
    echo "Illegal number of parameters." >&2
    printHelp >&2
    exit 1
  fi

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
  echo "Downloading the VM file."
  curl -f -L -O -C - "https://storage.googleapis.com/appcircle-dev-common/self-hosted/$vmImageFile"
  if [[ "$?" != 0 ]]; then
    if [[ "$retryAttempt" -gt "$retryMaxLimit" ]]; then
      retryAttempt=$((retryAttempt - 1))
      echo "Failed to download the VM image in $retryAttempt attempt. Please check your network." >&2
      exit 1
    fi
    echo "Download failed. Re-trying: $retryAttempt."
    retryAttempt=$((retryAttempt + 1))
    sleep $retryInterval
    downloadVmImage
  fi
}

extractVmFile() {
  echo "Extracting the VM file."
  tar -zxf macOS_230921.tar.gz --directory "$HOME/.tart/vms/macOS_230921"
  if [[ $? -ne 0 ]]; then
    echo "Failed to extract the VM file." >&2
    exit 1
  fi

}

checkMd5Sum() {
  validMd5=$(curl -fsSL -I "https://storage.googleapis.com/appcircle-dev-common/self-hosted/$vmImageFile" | grep -i -w "etag" | cut -d '"' -f 2)
  echo "Valid MD5: $validMd5"
  downloadedMd5=$(md5 "$vmImageFile" | cut -d' ' -f4)
  echo "Downloaded File's MD5: $downloadedMd5"
  if [[ "$downloadedMd5" != "$validMd5" ]]; then
    echo "Your downloaded file is corrupted. Delete the $vmImageFile and run the script again." >&2
    exit 1
  fi
  echo "Your downloaded VM file is valid."
}

main() {
  parseArguments "$@"
  echo "Installing $vmImageName"
  downloadVmImage
  checkMd5Sum
  mkVmDir
  extractVmFile
  echo "The Appcircle Runner macOS VM has been installed successfully."
  echo "You can see the $vmImageName in the output of 'tart list' command."
  exit 0
}

main "$@"
