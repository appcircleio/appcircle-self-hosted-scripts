#!/usr/bin/env bash
set -o pipefail
retryAttempt=1
retryAttemptOrigin="${retryAttempt}"
retryInterval=30
retryMaxLimit=10
version=1.2.1
defaultBaseUrl="https://storage.googleapis.com/appcircle-dev-common/self-hosted"
# AC_RUNNER_IMAGE_BASE_URL points the downloads to a mirror of the default location, such as an artifact proxy.
baseUrl="${AC_RUNNER_IMAGE_BASE_URL:-$defaultBaseUrl}"
baseUrl="${baseUrl%/}"

isDefaultBaseUrl() {
  [[ "$baseUrl" == "$defaultBaseUrl" ]]
}

maskedBaseUrl() {
  # Hide credentials if they were put into the URL.
  printf '%s' "$baseUrl" | sed -E 's#://[^/@]+@#://***@#'
}

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
  printf '%s\n' "Environment:"
  printf '\t%s\n' "AC_RUNNER_IMAGE_BASE_URL: Download from this location instead of Appcircle, such as an artifact proxy. The runner version is required when it is set."
  printf '%s\n' "Credentials for the download location are read from ~/.netrc when it has an entry for that host."
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
  if [[ -z $runnerVersion ]] && ! isDefaultBaseUrl; then
    # The latest image is found through the Google Cloud Storage API, which a mirror does not serve.
    echo "AC_RUNNER_IMAGE_BASE_URL is set, so the runner version is required. For example: $0 260914" >&2
    exit 1
  fi
  if [[ -z $runnerVersion ]]; then
    vmImageName=$(getTheLatestVmImageName)
    xcodeImageName=$(getTheLatestXcodeImageName)
  else
    vmImageName="macOS_${runnerVersion}"
    xcodeImageName="xcodes_${runnerVersion}"
  fi
  vmImageFile="$vmImageName.tar.gz"
  xcodeImageFile="$xcodeImageName.tar.gz"

}

getTheLatestVmImageName() {
  latestVmImageName=$(getTheLatestFile "macOS_*.tar.gz")
  echo "$latestVmImageName"
}

getTheLatestXcodeImageName() {
  latestXcodeImageName=$(getTheLatestFile "xcodes_*.tar.gz")
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
  fileToDownload=$1
  curl --netrc-optional -f -L -O -C - "${baseUrl}/$fileToDownload"
  if [[ "$?" != 0 ]]; then
    if [[ "$retryAttempt" -gt "$retryMaxLimit" ]]; then
      echo "Failed to download $fileToDownload in $((retryAttempt - 1)) attempt. Please check your network." >&2
      exit 1
    fi
    echo "Download failed. Re-trying: $retryAttempt."
    retryAttempt=$((retryAttempt + 1))
    sleep $retryInterval
    downloadFileFromBucket "$1"
  fi
}

downloadVmImage() {
  echo "Downloading the VM image..."
  retryAttempt="${retryAttemptOrigin}"
  downloadFileFromBucket "$vmImageFile"
}

downloadXcodeImages() {
  echo "Downloading the Xcode images..."
  retryAttempt="${retryAttemptOrigin}"
  downloadFileFromBucket "$xcodeImageFile"
}

extractVmFile() {
  echo "Extracting the VM image..."
  targetVmDir="$HOME/.tart/vms/$vmImageName"
  extractFile "${vmImageFile}" "${targetVmDir}"
}

extractXcodeFile() {
  echo "Extracting the Xcode images..."
  targetXcodeDir="$HOME/images"
  extractFile "${xcodeImageFile}" "${targetXcodeDir}"
}

extractFile() {
  fileToExtract=$1
  extractTargetPath=$2
  # -S writes all-zero blocks as holes, so the 360 GB sparse disk.img keeps
  # taking only its data size even when the sparse map is not honored.
  if ! pigz --version &>/dev/null; then
    echo "INFO: pigz command not found. Using the default gzip for extraction."
    tar -S -zxf "$fileToExtract" --directory "$extractTargetPath"
  else
    pigz -cvdp 4 "$fileToExtract" | tar -S -xvf - --directory "$extractTargetPath"
  fi
  if [[ "$?" != 0 ]]; then
    echo "Failed to extract the Tar file. $fileToExtract" >&2
    exit 1
  fi
  echo "$fileToExtract is extracted to the $extractTargetPath"
}

verifyChecksumVm() {
  verifyChecksum "$vmImageFile"
}

verifyChecksumXcode() {
  verifyChecksum "$xcodeImageFile"
}

verifyChecksum() {
  fileToCheck=$1
  if ! validMd5=$(getValidMd5 "$fileToCheck"); then
    exit 1
  fi
  checkMd5Sum "$fileToCheck" "$validMd5"
}

# Prints the expected MD5 of the file: from the <file>.md5 file next to it, or, for the default
# location only, from the ETag header. A mirror serves its own ETag, so it must serve <file>.md5.
getValidMd5() {
  fileToCheck=$1
  checksum=$(curl --netrc-optional -fsSL "${baseUrl}/${fileToCheck}.md5" 2>/dev/null | awk 'NR == 1 { print tolower($1) }')
  if [[ -n "$checksum" ]]; then
    if [[ ! "$checksum" =~ ^[0-9a-f]{32}$ ]]; then
      echo "The checksum file ${fileToCheck}.md5 doesn't contain a valid MD5 checksum." >&2
      return 1
    fi
    echo "$checksum"
    return 0
  fi
  if isDefaultBaseUrl; then
    checksum=$(curl -fsSL -I "${defaultBaseUrl}/$fileToCheck" | grep -i -w "etag" | cut -d '"' -f 2)
    if [[ -z "$checksum" ]]; then
      echo "Failed to get the md5 hash of origin file. Please check your network." >&2
      return 1
    fi
    echo "$checksum"
    return 0
  fi
  echo "Failed to download the checksum file ${fileToCheck}.md5 from $(maskedBaseUrl). The download location must serve it next to $fileToCheck." >&2
  return 1
}

checkMd5Sum() {
  fileToCheck=$1
  validMd5=$2
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
  echo "Download location: $(maskedBaseUrl)"
  echo "It may take some time to complete with respect to your network speed. Please wait patiently..."
  downloadVmImage
  downloadXcodeImages
  verifyChecksumVm
  verifyChecksumXcode
  mkVmDir
  mkXcodeDir
  extractVmFile
  extractXcodeFile
  echo "The Appcircle runner macOS VM and Xcode images have been installed successfully."
  if tart --version &>/dev/null; then
    echo "You can see the $vmImageName in the output of 'tart list' command."
  fi
  exit 0
}

main "$@"
