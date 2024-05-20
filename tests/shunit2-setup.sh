#!/usr/bin/env bash

checkShunit2(){
  command -v shunit2 &> /dev/null || (echo "shunit2 is not installed." ; exit 1)
}

setupDependencyPath(){
  testDepsPath="$(pwd)/tests/deps/bin"
  export PATH="$PATH:${testDepsPath}"
}

main(){
  setupDependencyPath
  checkShunit2
}

main
