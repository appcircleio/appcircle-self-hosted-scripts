#!/usr/bin/env bash

source ./tests/shunit2-setup.sh

# The functions are sourced, so these tests need no Tart, no VM and no network.
RUNNER_VM_SOURCED=1 source ./runner-vm.sh
set +eu +o pipefail
trap - EXIT

oneTimeSetUp() {
  workDir="$(mktemp -d)"
  CFG="$workDir/config"
  mkdir -p "$CFG"
  # A private root, a leaf it signs, and a self-signed leaf-like certificate.
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$workDir/root.key" -out "$workDir/root.pem" \
    -subj "/CN=Test Root CA" -days 30 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -keyout "$workDir/leaf.key" -out "$workDir/leaf.csr" \
    -subj "/CN=git.example.test" 2>/dev/null
  printf 'subjectAltName=DNS:git.example.test\n' >"$workDir/ext.cnf"
  openssl x509 -req -in "$workDir/leaf.csr" -CA "$workDir/root.pem" -CAkey "$workDir/root.key" \
    -CAcreateserial -out "$workDir/leaf.pem" -days 30 -extfile "$workDir/ext.cnf" 2>/dev/null
}

oneTimeTearDown() {
  [[ "${_shunit_name_}" = 'EXIT' ]] && return 0
  rm -rf "$workDir"
}

testEnvGetReadsValuesWithoutExecutingThem() {
  cat >"$CFG/host.env" <<'EOF'
# comment
AC_BASE_API_URL=https://api.example.test/build/v1
PROXY_PASSWORD="p@ss=word $(touch /tmp/runner-vm-test-should-not-exist)"
VM_CPU=4
VM_CPU=6
EOF
  assertEquals "https://api.example.test/build/v1" "$(env_get AC_BASE_API_URL)"
  assertEquals 'p@ss=word $(touch /tmp/runner-vm-test-should-not-exist)' "$(env_get PROXY_PASSWORD)"
  assertEquals "the last line wins" "6" "$(env_get VM_CPU)"
  assertEquals "" "$(env_get MISSING)"
  assertFalse "a value is never executed" "[ -e /tmp/runner-vm-test-should-not-exist ]"
}

testRunnerNamesFollowTheServerRule() {
  assertTrue "valid_name runner1"
  assertTrue "valid_name mac-mini_02"
  assertFalse "too short" "valid_name run1"
  assertFalse "too long" "valid_name abcdefghijklmnopqrstuvwxy"
  assertFalse "space" "valid_name 'runner 1'"
  assertFalse "dot" "valid_name runner.1"
}

testImageVersions() {
  assertTrue "valid_version 261102"
  assertFalse "valid_version macOS_261102"
  assertFalse "valid_version 26110"
}

testCatalogPairsImagesWithRunSh() {
  assertEquals "1.11.0" "$(catalog_field 261102 4)"
  assertEquals "26" "$(catalog_field 261102 3)"
  assertEquals "1.6.0" "$(catalog_field 260723 4)"
  assertEquals "an unknown image has no entry" "" "$(catalog_field 999999 4)"
  # every catalog line has five fields and a six-digit version
  assertEquals "0" "$(printf '%s\n' "$CATALOG" | awk -F'|' 'NF != 5 || $1 !~ /^[0-9]{6}$/' | wc -l | tr -d ' ')"
}

testNoProxyBecomesJavaNonProxyHosts() {
  assertEquals "localhost|127.0.0.1|*.example.test|git.corp.test" \
    "$(java_non_proxy "localhost, 127.0.0.1,.example.test,10.0.0.0/8,git.corp.test")"
}

testMaskedHidesUrlCredentials() {
  assertEquals "https://***@nexus.example.test/repo" "$(masked "https://user:secret@nexus.example.test/repo")"
  assertEquals "https://nexus.example.test/repo" "$(masked "https://nexus.example.test/repo")"
}

testUrlHost() {
  assertEquals "api.example.test" "$(url_host "https://api.example.test/build/v1")"
  assertEquals "api.example.test" "$(url_host "https://api.example.test:8443/x")"
}

testSplitPemAndFingerprints() {
  cat "$workDir/root.pem" "$workDir/leaf.pem" >"$workDir/bundle.pem"
  split_pem "$workDir/bundle.pem" "$workDir/split"
  assertEquals "2" "$(ls "$workDir/split" | wc -l | tr -d ' ')"
  assertEquals "2" "$(fingerprints "$workDir/split" | wc -l | tr -d ' ')"
  assertContains "$(openssl x509 -in "$workDir/split/0001.pem" -noout -subject)" "Test Root CA"
}

testInitWritesATemplateOnce() {
  local cfg="$workDir/init"
  CFG="$cfg" cmd_init >/dev/null 2>&1
  assertTrue "host.env" "[ -f '$cfg/host.env' ]"
  assertEquals "700" "$(stat -f '%Lp' "$cfg")"
  assertEquals "600" "$(stat -f '%Lp' "$cfg/host.env")"
  assertEquals "half of the cores" "$(( $(sysctl -n hw.ncpu) / 2 ))" "$(CFG="$cfg" env_get VM_CPU)"
  assertEquals "half of the memory" "$(( $(sysctl -n hw.memsize) / 1073741824 / 2 * 1024 ))" "$(CFG="$cfg" env_get VM_MEMORY_MB)"
  ( CFG="$cfg" cmd_init >/dev/null 2>&1 )
  assertNotEquals "a second init refuses to overwrite" "0" "$?"
}

testGuestScriptsAreValidZsh() {
  guest_apply >"$workDir/apply.zsh"
  guest_collect >"$workDir/collect.zsh"
  zsh -n "$workDir/apply.zsh"
  assertEquals "guest_apply" "0" "$?"
  zsh -n "$workDir/collect.zsh"
  assertEquals "guest_collect" "0" "$?"
}

# A stub tart that keeps its VMs as empty files, to test the renames of an upgrade and a rollback.
tart() {
  case $1 in
    list) echo "Source Name"; for f in "$TART_DIR"/*; do [ -f "$f" ] && echo "local $(basename "$f")"; done ;;
    rename) mv "$TART_DIR/$2" "$TART_DIR/$3" ;;
    delete) rm "$TART_DIR/$2" ;;
    stop) return 0 ;;
  esac
}
runsh_cache() { echo "$workDir/run-$1.sh"; }

setUpSwitch() {
  TART_DIR="$workDir/tart"; RUNNERS_ROOT="$workDir/runners"
  rm -rf "$TART_DIR" "$RUNNERS_ROOT"; mkdir -p "$TART_DIR" "$RUNNERS_ROOT/runner1"
  echo old >"$RUNNERS_ROOT/runner1/run.sh"; echo new >"$workDir/run-1.11.0.sh"
  touch "$TART_DIR/runner1" "$RUNNERS_ROOT/runner1/.stopped"
}

testSwitchInKeepsThePreviousVmAndRunSh() {
  setUpSwitch
  echo built >"$TART_DIR/runner1-new"
  touch "$TART_DIR/runner1-prev"   # an older rollback copy is replaced
  switch_in runner1 1.11.0
  assertEquals "the new VM has the runner name" "built" "$(cat "$TART_DIR/runner1")"
  assertTrue "the previous VM is kept" "[ -f '$TART_DIR/runner1-prev' ]"
  assertFalse "no -new VM is left" "[ -e '$TART_DIR/runner1-new' ]"
  assertEquals "new" "$(cat "$RUNNERS_ROOT/runner1/run.sh")"
  assertEquals "old" "$(cat "$RUNNERS_ROOT/runner1/run.sh.prev")"
  assertFalse "the stop marker is cleared" "[ -e '$RUNNERS_ROOT/runner1/.stopped' ]"
}

testSwitchInForANewRunner() {
  setUpSwitch
  rm "$TART_DIR/runner1"; touch "$TART_DIR/runner2-new"
  switch_in runner2 1.11.0
  assertTrue "[ -f '$TART_DIR/runner2' ]"
  assertFalse "nothing to keep" "[ -e '$TART_DIR/runner2-prev' ]"
  assertEquals "new" "$(cat "$RUNNERS_ROOT/runner2/run.sh")"
}

testRollBackRestoresVmAndRunSh() {
  setUpSwitch
  echo built >"$TART_DIR/runner1-new"
  switch_in runner1 1.11.0
  roll_back runner1
  assertEquals "the previous VM is back" "" "$(cat "$TART_DIR/runner1")"
  assertFalse "[ -e '$TART_DIR/runner1-prev' ]"
  assertEquals "old" "$(cat "$RUNNERS_ROOT/runner1/run.sh")"
  ( roll_back runner1 >/dev/null 2>&1 )
  assertNotEquals "a second rollback has nothing to go back to" "0" "$?"
}

testUnknownImageIsRefused() {
  ( cmd_pull 999999 >/dev/null 2>&1 )
  assertNotEquals "0" "$?"
}

source shunit2
