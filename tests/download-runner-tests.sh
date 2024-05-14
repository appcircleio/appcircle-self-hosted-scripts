#!/usr/bin/env bash

source ./tests/shunit2-setup.sh

testRunnerDownload(){
  echo "${testId} test starting"
  $runnerDownloadScript test &> "$stdoutF"

  macOSValidMd5="bcf4afb27d8da7034577047979715934"
  assertContains "Valid remote MD5 for macOS images should be found." "$(cat "${stdoutF}")" "Valid MD5: $macOSValidMd5"
  assertContains "MD5 check for macOS image should be successfull." "$(cat "${stdoutF}")" "Your downloaded file macOS_test.tar.gz is valid"
  
  xcodesValidMd5="bcf4afb27d8da7034577047979715934"
  assertContains "Valid remote MD5 for Xcode images should be found." "$(cat "${stdoutF}")" "Valid MD5: $xcodesValidMd5"
  assertContains "MD5 check for Xcodes image should be successfull." "$(cat "${stdoutF}")" "Your downloaded file xcodes_test.tar.gz is valid"


  tartVmsDirectory="$HOME/.tart/vms"
  assertContains "MacOS image should be extracted successfully." "$(cat "${stdoutF}")" "macOS_test.tar.gz is extracted to the $tartVmsDirectory/macOS_test"
  assertContains "MacOS image directory should be found in the \"$HOME/.tart/vms\" directory." "$(ls -l "$tartVmsDirectory")" "macOS_test"
  
  # @TODO: Will be uncommented after the macOS_test test file meets the requirements. 
  #assertContains "MacOS VM directory should contain \"config.json\" file." "$(ls -l "$tartVmsDirectory/macOS_test")" "config.json"
  #assertContains "MacOS VM directory should contain \"nvram.bin\" file." "$(ls -l "$tartVmsDirectory/macOS_test")" "nvram.bin"
  #assertContains "MacOS VM directory should contain \"disk.img\" file." "$(ls -l "$tartVmsDirectory/macOS_test")" "disk.img"

  assertContains "Xcode images should be extracted successfully." "$(cat "${stdoutF}")" "xcodes_test.tar.gz is extracted to the $HOME/images"
  assertContains "Xcode images directory should be found in the \"$HOME\" directory." "$(ls -l "$HOME")" "images"
  
  # @TODO: Will be uncommented after the macOS_test test file meets the requirements. 
  assertContains "Xcode images directory should contain some dmg files." "$(ls -l "$HOME/images")" "dmg"
  
  # @TODO: Will be uncommented after the macOS_test test file meets the requirements. 
  #assertContains "Tart list should contain the new macOS VM name" "$(tart list)" "macOS_test"

  assertContains "Script output should container success log." "$(cat "${stdoutF}")" "The Appcircle runner macOS VM and Xcode images have been installed successfully"

}


oneTimeSetUp() {
  runnerDownloadScript="bash ./download-runner.sh"
}

setUp() {
  testId="test-${RANDOM}-${RANDOM}"
  testReportPath="./tests/reports/${testId}"
  stdoutF="${testReportPath}/stdout"
  #stderrF="${testReportPath}/stderr"
  mkdir -p "$testReportPath"
  echo "You can see the outputs in $testReportPath folder"
  rm -f macOS_test.tar.gz xcodes_test.tar.gz
}

# shellcheck disable=2154
tearDown() {
  [[ "${_shunit_name_}" = 'EXIT' ]] && return 0
  rm -f macOS_test.tar.gz xcodes_test.tar.gz
}

oneTimeTearDown() {
  [[ "${_shunit_name_}" = 'EXIT' ]] && return 0
  echo "Tests finished."
}

source shunit2
