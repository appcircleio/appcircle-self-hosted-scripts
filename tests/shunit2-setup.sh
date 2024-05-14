#!/usr/bin/env bash

checkShunit2(){
  command -v shunit2 &> /dev/null || (echo "shunit2 is not installed." ; exit 1)
}

setupDependencyPath(){
  depsPath="$(pwd)/deps/bin"
  testDepsPath="$(pwd)/tests/deps/bin"
  export PATH="$PATH:${depsPath}:${testDepsPath}"
}

main(){
  setupDependencyPath
  checkShunit2
}

main
