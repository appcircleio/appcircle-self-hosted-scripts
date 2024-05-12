#!/usr/bin/env bash
set -o pipefail
retryAttempt=1
retryInterval=30
retryMaxLimit=10
version=1.0.0

mkVmDir() {
  mkdir -p "${HOME}/.tart/vms/${vmImageName}"
}

mkXcodeDir() {
  mkdir -p "${HOME}/images"
}

printVersion() {
  echo "${version}"
}

printHelp() {
  printf '%s\n' "Download, extract, validate, and install macOS VM and Xcode images."
  printf '%s\n' "By default, latest macOS VM and Xcode image will be installed."
  printf 'Usage: %s [runner-version] [-h|--help]\n' "$0"
  printf '\t%s\n' "runner-version: Specify the Appcircle runner version optionally."
  printf '\t%s\n' "-h, --help: Prints help."
  printf '\t%s\n' "-v, --version: Prints version."
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

  runnerVersion=$1
  if [[ -z $runnerVersion ]]; then
    vmImageName=$(getTheLatestVmImageName)
    xcodeImageName=$(getTheLatestXcodeImageName)
  else
    vmImageName="macOS_${runnerVersion}"
    xcodeImageName="xcode_${runnerVersion}"
  fi
  vmImageFile="$vmImageName.tar.gz"
  xcodeImageFile="$xcodeImageName.tar.gz"

}

getTheLatestVmImageName() {
  latestVmImageName=$(getTheLatestFile "macOS*")
  echo "$latestVmImageName"
}

getTheLatestXcodeImageName() {
  latestXcodeImageName=$(getTheLatestFile "xcodes*")
  echo "$latestXcodeImageName"
}

getTheLatestFile() {
  fileToSearch=$1
  fileList=$(curl -fsSL -X GET "https://storage.googleapis.com/storage/v1/b/appcircle-dev-common/o?matchGlob=self-hosted/${fileToSearch}")
  latestRunner=$(echo "$fileList" | grep -o '"name": "[^"]*' | tail -n 1)
  fileName=$(basename "$latestRunner")
  echo "${fileName%.tar.gz}"
}

downloadFileFromBucket() {
  set -x
  fileToDownload=$1
  curl -f -L -O -C - "https://storage.googleapis.com/appcircle-dev-common/self-hosted/$fileToDownload"
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

downloadVmImage() {
  echo "Downloading the VM file."
  downloadFileFromBucket "$vmImageFile"
}

downloadXcodeImages() {
  echo "Downloading the Xcode images."
  downloadFileFromBucket "$xcodeImageFile"
}

extractVmFile() {
  echo "Extracting the VM file."
  targetVmDir="$HOME/.tart/vms/$vmImageName"
  extractFile "${vmImageFile}" "${targetVmDir}"
}

extractXcodeFile() {
  echo "Extracting the Xcode file."
  targetXcodeDir="$HOME/images"
  extractFile "${xcodeImageFile}" "${targetXcodeDir}"
}

extractFile() {
  fileToExtract=$1
  extractTargetPath=$2
  tar -zxf "${fileToExtract}" --directory "${extractTargetPath}"
  if [[ "$?" != 0 ]]; then
    echo "Failed to extract the Tar file. $fileToExtract" >&2
    exit 1
  fi
  echo "$fileToExtract is extracted to the $extractTargetPath"
}

checkMd5SumVm() {
  checkMd5Sum "$vmImageFile"
}

checkMd5SumXcode() {
  checkMd5Sum "$xcodeImageFile"
}

checkMd5Sum() {
  fileToCheck=$1
  validMd5=$(curl -fsSL -I "https://storage.googleapis.com/appcircle-dev-common/self-hosted/$fileToCheck" | grep -i -w "etag" | cut -d '"' -f 2)
  if [[ $? -ne 0 ]]; then
    echo "Failed to get the md5 hash of origin file. Please check your network." >&2
    exit 1
  fi
  echo "Valid MD5: $validMd5"
  md5Cli=""
  os=$(uname -s)
  if [[ $os == "Darwin" ]]; then
    md5Cli="md5"
  elif [[ $os == "Linux" ]]; then
    md5Cli="md5sum"
  fi
  if ! command -v $md5Cli &>/dev/null; then
    echo "$md5Cli command not found." >&2
    exit 1
  fi
  downloadedMd5=$($md5Cli "$fileToCheck" | cut -d' ' -f4)
  echo "Downloaded File's MD5: $downloadedMd5"
  if [[ "$downloadedMd5" != "$validMd5" ]]; then
    echo "Your downloaded file is corrupted. Delete the $fileToCheck and run the script again." >&2
    exit 1
  fi
  echo "Your downloaded file $fileToCheck is valid."
}

main() {
  parseArguments "$@"
  echo "$vmImageName image with $xcodeImageName Xcodes will be installed..."
  echo "Please wait patiently..."
  downloadVmImage
  downloadXcodeImages
  checkMd5SumVm
  checkMd5SumXcode
  mkVmDir
  mkXcodeDir
  extractVmFile
  extractXcodeFile
  echo "The Appcircle Runner macOS VM and Xcode images has been installed successfully."
  if tart --version &>/dev/null; then
    echo "You can see the $vmImageName in the output of 'tart list' command."
  fi
  exit 0
}

main "$@"
