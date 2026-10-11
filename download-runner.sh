#!/usr/bin/env bash
set -o pipefail
retryAttempt=1
retryAttemptOrigin="${retryAttempt}"
retryInterval=30
retryMaxLimit=10
version=1.2.0-beta
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
  if ! pigz --version &>/dev/null; then
    echo "INFO: pigz command not found. Using the default gzip for extraction."
    tar -zxf "$fileToExtract" --directory "$extractTargetPath"
  else
    pigz -cvdp 4 "$fileToExtract" | tar xvf - --directory "$extractTargetPath"
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
  if checkSha256Sum "$fileToCheck"; then
    return 0
  fi
  # Only the default location serves the MD5 checksum as the ETag header. A mirror serves its own ETag.
  if isDefaultBaseUrl; then
    echo "INFO: No SHA-256 checksum file was found for $fileToCheck. Checking the MD5 checksum instead."
    checkMd5Sum "$fileToCheck"
    return 0
  fi
  echo "Failed to download the checksum file ${fileToCheck}.sha256 from $(maskedBaseUrl). The download location must serve it next to $fileToCheck." >&2
  exit 1
}

# Returns 1 if the checksum file can't be downloaded. Exits if the checksum doesn't match.
checkSha256Sum() {
  fileToCheck=$1
  checksumFile="${fileToCheck}.sha256"
  rm -f "$checksumFile"
  if ! curl --netrc-optional -fsSL -o "$checksumFile" "${baseUrl}/${checksumFile}"; then
    rm -f "$checksumFile"
    return 1
  fi
  validSha256=$(awk 'NR == 1 { print tolower($1) }' "$checksumFile")
  rm -f "$checksumFile"
  if [[ ! "$validSha256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "The checksum file $checksumFile doesn't contain a valid SHA-256 checksum." >&2
    exit 1
  fi
  echo "Valid SHA-256: $validSha256"
  sha256Cli=()
  os=$(uname -s)
  if [[ $os == "Darwin" ]]; then
    sha256Cli=(shasum -a 256)
  elif [[ $os == "Linux" ]]; then
    sha256Cli=(sha256sum)
  fi
  if [[ ${#sha256Cli[@]} -eq 0 ]] || ! command -v "${sha256Cli[0]}" &>/dev/null; then
    echo "No SHA-256 command was found." >&2
    exit 1
  fi
  echo "Calculating the SHA-256 checksum of $fileToCheck. It may take a few minutes..."
  downloadedSha256=$("${sha256Cli[@]}" "$fileToCheck" | awk '{ print tolower($1) }')
  echo "Downloaded File's SHA-256: $downloadedSha256"
  if [[ "$downloadedSha256" != "$validSha256" ]]; then
    echo "Your downloaded file is corrupted. Delete the $fileToCheck and run the script again." >&2
    exit 1
  fi
  echo "Your downloaded file $fileToCheck is valid."
}

checkMd5Sum() {
  fileToCheck=$1
  validMd5=$(curl -fsSL -I "${defaultBaseUrl}/$fileToCheck" | grep -i -w "etag" | cut -d '"' -f 2)
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
