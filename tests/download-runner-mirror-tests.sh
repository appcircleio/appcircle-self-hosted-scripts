#!/usr/bin/env bash

# Tests download-runner.sh with AC_RUNNER_IMAGE_BASE_URL against a local mirror.
# No internet access is needed. Requires python3.

source ./tests/shunit2-setup.sh

testMirrorDownloadWithChecksum() {
  startMirror ""
  runDownload "${mirrorUrl}/" "test1"

  assertEquals "Script should succeed." "0" "$exitCode"
  assertContains "SHA-256 checksum should be read from the mirror." "$(cat "$outputFile")" "Valid SHA-256: "
  assertContains "Script output should contain success log." "$(cat "$outputFile")" "The Appcircle runner macOS VM and Xcode images have been installed successfully"
  assertTrue "macOS image should be extracted into the tart VMs folder." "[ -f '${homeDir}/.tart/vms/macOS_test1/config.json' ]"
  assertTrue "Xcode images should be extracted into the images folder." "[ -f '${homeDir}/images/xcode.1.0.dmg' ]"
}

testMirrorRequiresVersion() {
  startMirror ""
  runDownload "$mirrorUrl" ""

  assertEquals "Script should fail." "1" "$exitCode"
  assertContains "Script should ask for the runner version." "$(cat "$outputFile")" "the runner version is required"
  assertFalse "Nothing should be downloaded." "ls '${runDir}'/*.tar.gz"
}

testMirrorChecksumMismatch() {
  printf '%064d  macOS_test1.tar.gz\n' 0 >"${mirrorDir}/macOS_test1.tar.gz.sha256"
  startMirror ""
  runDownload "$mirrorUrl" "test1"

  assertEquals "Script should fail." "1" "$exitCode"
  assertContains "Script should report a corrupted file." "$(cat "$outputFile")" "Your downloaded file is corrupted"
}

testMirrorMissingChecksumFile() {
  rm -f "${mirrorDir}/xcodes_test1.tar.gz.sha256"
  startMirror ""
  runDownload "$mirrorUrl" "test1"

  assertEquals "Script should fail." "1" "$exitCode"
  assertContains "Script should name the missing checksum file." "$(cat "$outputFile")" "Failed to download the checksum file xcodes_test1.tar.gz.sha256"
}

testMirrorWithNetrcCredentials() {
  startMirror "runner:secret"

  runDownload "$mirrorUrl" "test1"
  assertEquals "Script should fail without credentials." "1" "$exitCode"

  rm -f "${runDir}"/*.tar.gz
  printf 'machine 127.0.0.1 login runner password secret\n' >"${homeDir}/.netrc"
  chmod 600 "${homeDir}/.netrc"
  runDownload "$mirrorUrl" "test1"
  assertEquals "Script should succeed with credentials in ~/.netrc." "0" "$exitCode"
  assertTrue "macOS image should be extracted." "[ -f '${homeDir}/.tart/vms/macOS_test1/config.json' ]"
}

testMirrorUrlHidesCredentials() {
  startMirror "runner:secret"
  runDownload "http://runner:secret@${mirrorUrl#http://}" "test1"

  assertEquals "Script should succeed with credentials in the URL." "0" "$exitCode"
  assertContains "Download location should be logged." "$(cat "$outputFile")" "Download location: http://***@127.0.0.1"
  assertNotContains "Credentials should not be logged." "$(cat "$outputFile")" "secret"
}

createImages() {
  imageVersion=$1
  mkdir -p "${workDir}/src/vm" "${workDir}/src/xcodes"
  echo "{}" >"${workDir}/src/vm/config.json"
  echo "dmg" >"${workDir}/src/xcodes/xcode.1.0.dmg"
  tar -czf "${mirrorDir}/macOS_${imageVersion}.tar.gz" -C "${workDir}/src/vm" .
  tar -czf "${mirrorDir}/xcodes_${imageVersion}.tar.gz" -C "${workDir}/src/xcodes" .
  for image in macOS xcodes; do
    (cd "$mirrorDir" && shasum -a 256 "${image}_${imageVersion}.tar.gz" >"${image}_${imageVersion}.tar.gz.sha256")
  done
}

startMirror() {
  portFile="${workDir}/port"
  MIRROR_AUTH="$1" python3 -I "$mirrorServer" "$mirrorDir" "$portFile" &>"${workDir}/mirror.log" &
  mirrorPid=$!
  for _ in $(seq 1 50); do
    [[ -s "$portFile" ]] && break
    sleep 0.1
  done
  mirrorUrl="http://127.0.0.1:$(cat "$portFile")"
}

runDownload() {
  # shellcheck disable=2086
  (cd "$runDir" && HOME="$homeDir" AC_RUNNER_IMAGE_BASE_URL="$1" bash "$testScript" $2) &>"$outputFile"
  exitCode=$?
}

oneTimeSetUp() {
  # Run a copy without retry delays, so failing downloads end quickly.
  testScript=$(mktemp)
  sed "s/retryInterval=30/retryInterval=0/; s/retryMaxLimit=10/retryMaxLimit=0/" "./download-runner.sh" >"$testScript"
  mirrorServer="$(pwd)/tests/mirror-server.py"
}

setUp() {
  workDir=$(mktemp -d)
  mirrorDir="${workDir}/mirror"
  homeDir="${workDir}/home"
  runDir="${workDir}/run"
  outputFile="${workDir}/output"
  mkdir -p "$mirrorDir" "$homeDir" "$runDir"
  createImages "test1"
}

# shellcheck disable=2154
tearDown() {
  [[ "${_shunit_name_}" = 'EXIT' ]] && return 0
  [[ -n "$mirrorPid" ]] && kill "$mirrorPid" 2>/dev/null && wait "$mirrorPid" 2>/dev/null
  mirrorPid=""
  rm -rf "$workDir"
}

oneTimeTearDown() {
  [[ "${_shunit_name_}" = 'EXIT' ]] && return 0
  rm -f "$testScript"
  echo "Tests finished."
}

source shunit2
