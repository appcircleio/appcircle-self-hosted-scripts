#!/usr/bin/env bash
set -o pipefail
retryAttempt=1
retryInterval=30
retryMaxLimit=10
version=v1.0.0
acScriptSelfHosted="$AC_SERVER_PATH"/ac-self-hosted.sh
projectName=""

printVersion() {
  echo "${version}"
}

printHelp() {
  printf '%s\n' "Check and update the Appcircle Server if there is a new version."
  printf '%s\n' "By default, latest Appcircle Server will be installed."
  printf 'Usage: %s -n "projectName" [-h|--help]\n' "$0"
  printf '\t%s\n' "-n 'projectName': Specify the Appcircle project name."
  printf '\t%s\n' "-h, --help: Prints help."
  printf '\t%s\n' "-v, --version: Prints version of this script."
}

parseArguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
    --help | -h)
      printHelp
      exit 0
      ;;
    --version | -v)
      printVersion
      exit 0
      ;;
    -n)
      shift
      projectName="$1"
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
    esac
    shift
  done

  if [[ "$#" -ne 0 ]] && [[ "$#" -ne 1 ]]; then
    echo "Illegal number of parameters." >&2
    printHelp >&2
    exit 1
  fi

  appcirclePackageName=$1
  if [[ -z $appcirclePackageName ]]; then
    appcirclePackageName=$(getTheLatestAppcirclePackageName)
  fi
  appcirclePackageFile="$appcirclePackageName.zip"
}

getTheLatestAppcirclePackageName() {
  latestServerPackageName=$(getTheLatestFile "*appcircle-server*")
  echo "$latestServerPackageName"
}

getTheLatestFile() {
  fileToSearch=$1
  fileList=$(curl -fsSL -X GET "https://storage.googleapis.com/storage/v1/b/appcircle-dev-common/o?matchGlob=self-hosted/temp/${fileToSearch}")
  latestServerFile=$(echo "$fileList" | grep -o '"name": "[^"]*')
  fileName=$(basename "$latestServerFile")
  echo "${fileName%.zip}"
}

downloadAppcircleServerPackage() {
  echo "Downloading the Appcircle Server file."
  downloadFileFromBucket "$appcirclePackageFile"
}

parseLatestAppcircleServerVersion() {
  # Define the regular expression pattern to match the version number
  pattern='([0-9]+\.[0-9]+\.[0-9]+)'

  # Use grep with the regular expression pattern to extract the version number
  if [[ $appcirclePackageName =~ $pattern ]]; then
    latestAppcircleServerVersion="${BASH_REMATCH[1]}"
  else
    echo "Version number not found in the filename."
    exit 1
  fi
}

downloadFileFromBucket() {
  fileToDownload=$1
  curl -f -L -O -C - "https://storage.googleapis.com/appcircle-dev-common/self-hosted/temp/$fileToDownload"
  # shellcheck disable=SC2181
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

checkMd5Sum() {
  fileToCheck=$1
  validMd5=$(curl -fsSL -I "https://storage.googleapis.com/appcircle-dev-common/self-hosted/temp/$fileToCheck" | grep -i -w "etag" | cut -d '"' -f 2)
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
  downloadedMd5=$($md5Cli "$fileToCheck" | cut -d' ' -f1)
  echo "Downloaded File's MD5: $downloadedMd5"
  if [[ "$downloadedMd5" != "$validMd5" ]]; then
    echo "Your downloaded file is corrupted. Delete the $fileToCheck and run the script again." >&2
    exit 1
  fi
  echo "Your downloaded file $fileToCheck is valid."
}

checkMd5SumAppcircleServer() {
  checkMd5Sum "$appcirclePackageFile"
}

compareAppcircleServerVersion() {
  currentAppcircleServerVersion=$("$acScriptSelfHosted" --version)
  echo "Current Appcircle server package: $currentAppcircleServerVersion"
  echo "Comparing the versions"
  if [[ "$currentAppcircleServerVersion" == "$latestAppcircleServerVersion" ]]; then
    echo "You are already up to date."
    exit 0
  else
    verlte "$currentAppcircleServerVersion" "$latestAppcircleServerVersion"
    # shellcheck disable=SC2181
    if [[ "$?" == "0" ]]; then
      echo "There is a new Appcircle server"
      return 0
    else
      echo "You are already up to date"
      exit 0
    fi
  fi
}

verlte() {
  printf '%s\n' "$1" "$2" | sort -C -V
}

cdIntoParentDirectoryAppcircleServer() {
  cd "$(dirname "$AC_SERVER_PATH")" || exit 1
}

cdIntoAppcircleServerDirectory() {
  cd "$AC_SERVER_PATH" || exit 1
}

stopAppcircleServer() {
  echo "Stopping the Appcircle Server."
  $acScriptSelfHosted -n "$projectName" down
}

unzipTheNewPackage() {
  echo "Unzipping the new Appcircle Server package."
  unzip -o -u "$appcirclePackageFile" -d appcircle-server
}

installDependencies() {
  echo "Installing Appcircle Server dependencies."
  # echo 1 for docker or 2 for podman
  echo "1" | sudo "$acScriptSelfHosted" -i
}

exportNewConfiguration() {
  echo "Exporting new configuration."
  "$acScriptSelfHosted" -n "$projectName" export
}

startAppcircleServer() {
  echo "Starting the Appcircle Server."
  $acScriptSelfHosted -n "$projectName" up
}

checkUpdatedVersion() {
  echo "Appcircle Server update has been completed."
  echo "New Appcircle Server version: $("$acScriptSelfHosted" --version)."
}

main() {
  parseArguments "$@"
  echo "Latest Appcircle server package: $appcirclePackageName."
  echo "URL: https://storage.googleapis.com/appcircle-dev-common/self-hosted/temp/$appcirclePackageFile"
  parseLatestAppcircleServerVersion
  compareAppcircleServerVersion
  cdIntoParentDirectoryAppcircleServer
  downloadAppcircleServerPackage
  checkMd5SumAppcircleServer
  stopAppcircleServer
  unzipTheNewPackage
  cdIntoAppcircleServerDirectory
  installDependencies
  exportNewConfiguration
  startAppcircleServer
  checkUpdatedVersion

  exit 0
}

main "$@"
