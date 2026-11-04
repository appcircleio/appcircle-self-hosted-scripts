#!/usr/bin/env bash
# ==============================================================================
# Appcircle self-hosted macOS runner host - VM manager
#
# One tool for the macOS host that runs Appcircle runners as Tart VMs: list the
# runner images and their Xcode versions, download an image, build ready runner
# VMs from it, register them, run them as launchd services, upgrade them to a
# new image and roll back.
#
# Every customization of the runner VMs (server settings, certificates, proxy,
# NTP, tools, files, the runner registrations) lives in one folder on the host,
# outside the VM image. A new image is never changed by hand: `create` and
# `upgrade` build the VMs from the image plus that folder, the same way on a
# first install and on every upgrade.
#
#   ./runner-vm.sh help
#
# Folder: $AC_RUNNER_CONFIG (default ~/appcircle-runner-config), mode 700.
# Runner name = Tart VM name = runner folder (~/<name>) = runners/<name>/.
# ==============================================================================
set -euo pipefail

VERSION="1.0.0"

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
CFG="${AC_RUNNER_CONFIG:-$HOME/appcircle-runner-config}"
IMAGE_BASE="${AC_RUNNER_IMAGE_BASE_URL:-https://storage.googleapis.com/appcircle-dev-common/self-hosted}"
IMAGE_BASE="${IMAGE_BASE%/}"
DEFAULT_IMAGE_BASE="https://storage.googleapis.com/appcircle-dev-common/self-hosted"
CDN_BASE="${AC_RUNNER_CDN_BASE_URL:-https://cdn.appcircle.io/self-hosted}"
CDN_BASE="${CDN_BASE%/}"
DOWNLOAD_DIR="${AC_RUNNER_DOWNLOAD_DIR:-$HOME/appcircle-downloads}"
IMAGES_DIR="$HOME/images"
RUNNERS_ROOT="${AC_RUNNERS_ROOT:-$HOME}"
GUEST_USER="appcircle"
GUEST_PASS="${AC_GUEST_PASSWORD:-cicd}" # the documented default of every image
GUEST_RUNNER="/Volumes/agent-disk/appcircle-runner"
BASE_VM="ac-base-build"
MIN_FREE_GB=20

# Images this version knows: version|guest macOS|host macOS major at least|run.sh|Xcode (build)
# Updated with every image release, together with the run.sh it pairs with.
CATALOG="261102|Tahoe 26.6.2|26|1.11.0|27.2 (27B52), 27.1 (27A9275), 27.0 (27A266a), 26.6 (17F113)
260723|Tahoe 26.3.2|26|1.6.0|26.6 (17F113), 26.5 (17F42), 26.4.1 (17E202), 26.3 (17C529)
260303|Sequoia 15.6.1|15|1.3.0|26.3 (17C529), 26.2 (17C52), 26.1.1 (17B100), 26.0.1 (17A400), 16.4 (16F6)
251015|Sequoia 15.6.1|15|1.0.9|26.0.1 (17A400), 16.4 (16F6), 16.3 (16E140), 16.2 (16C5032a), 16.1 (16B40), 16.0 (16A242d)"

# ------------------------------------------------------------------ output
if [ -t 1 ]; then c_r=$'\033[31m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_0=$'\033[0m'
else c_r=""; c_g=""; c_y=""; c_0=""; fi
log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }
ok() { printf '%s %s%s%s\n' "$(date '+%H:%M:%S')" "$c_g" "$*" "$c_0"; }
warn() { printf '%s %sWARN%s %s\n' "$(date '+%H:%M:%S')" "$c_y" "$c_0" "$*" >&2; }
die() { printf '%s %sERROR%s %s\n' "$(date '+%H:%M:%S')" "$c_r" "$c_0" "$*" >&2; exit 1; }

# ------------------------------------------------------------------ helpers
# host.env is read as KEY=VALUE lines, never sourced, so a value is data only.
env_get() {
  local line=""
  [ -f "$CFG/host.env" ] || return 0
  line=$(grep -E "^$1=" "$CFG/host.env" | tail -n 1 || true)
  line=${line#*=}
  line=${line#\"}; line=${line%\"}
  printf '%s' "$line"
}

valid_name() {
  # Server rule for runner names: 5-24 letters, digits, - or _. Kept ASCII here.
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_-]{5,24}$'
}

valid_version() { printf '%s' "$1" | grep -Eq '^[0-9]{6}$'; }

catalog_line() { printf '%s\n' "$CATALOG" | grep -E "^$1\|" || true; }
catalog_field() { catalog_line "$1" | cut -d'|' -f"$2"; }

# NO_PROXY "a,.b.c,10.0.0.0/8" -> Java nonProxyHosts "a|*.b.c" (CIDRs are not supported there)
java_non_proxy() {
  printf '%s' "$1" | tr ',' '\n' | sed -e 's/^ *//' -e 's/ *$//' | grep -v '/' | grep -v '^$' \
    | sed -e 's/^\./*./' | paste -sd'|' -
}

free_gb() { df -g "$HOME" | awk 'NR==2 {print $4}'; }
host_major() { sw_vers -productVersion | cut -d. -f1; }
url_host() { printf '%s' "$1" | sed -E 's#^[a-z]+://##; s#[/:].*$##'; }
masked() { printf '%s' "$1" | sed -E 's#://[^/@]+@#://***@#'; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required: $2"; }

tart_has() { tart list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$1"; }
# A `tart run` process that outlived its VM still holds one of the two VM slots macOS allows.
running() { pgrep -f "tart run $1( |\$)" >/dev/null 2>&1; }
running_count() { pgrep -f "tart run " 2>/dev/null | wc -l | tr -d ' '; }

LOCKED=0
cleanup() {
  [ -n "${AP:-}" ] && rm -f "$AP"
  [ "$LOCKED" = 1 ] && rm -rf "$CFG/.lock"
  return 0
}
trap cleanup EXIT

lock() {
  [ "$LOCKED" = 1 ] && return 0
  mkdir -p "$CFG" && chmod 700 "$CFG"
  if ! mkdir "$CFG/.lock" 2>/dev/null; then
    die "another runner-vm.sh is running (lock $CFG/.lock). Remove it only if no other run is active."
  fi
  LOCKED=1
}

start_log() {
  mkdir -p "$CFG/logs" && chmod 700 "$CFG/logs"
  LOGFILE="$CFG/logs/$1-$(date '+%Y%m%d-%H%M%S').log"
  : >"$LOGFILE" && chmod 600 "$LOGFILE"
  exec > >(tee -a "$LOGFILE") 2>&1
  log "runner-vm.sh $VERSION $*  (log: $LOGFILE)"
}

# ------------------------------------------------------------------ guest access
# The guest password goes through a temporary askpass helper: no sshpass, nothing on a command line.
AP=""
# shellcheck disable=SC2054 # "password,keyboard-interactive" is one option value
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
  -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive -o ConnectTimeout=5)
askpass() {
  [ -n "$AP" ] && return 0
  AP=$(mktemp /tmp/ac-askpass.XXXXXX)
  printf '#!/bin/sh\necho %s\n' "$GUEST_PASS" >"$AP"
  chmod 700 "$AP"
  export SSH_ASKPASS="$AP" SSH_ASKPASS_REQUIRE=force DISPLAY=:0
}
vmssh() { local ip=$1; shift; ssh "${SSH_OPTS[@]}" "$GUEST_USER@$ip" "$@" </dev/null; }
vmssh_in() { local ip=$1; shift; ssh "${SSH_OPTS[@]}" "$GUEST_USER@$ip" "$@"; }
vmscp() { scp -q -r "${SSH_OPTS[@]}" "$@" </dev/null; }

# boot <vm>: start without Xcode disks, wait for SSH, stop the runner service at once
# (an unregistered image polls the cloud and powers off after three 401 answers).
boot() {
  local vm=$1 ip=""
  askpass
  running "$vm" && die "$vm is already running"
  [ "$(running_count)" -lt 2 ] || die "two VMs are running already (the macOS limit); stop a runner first"
  tart run "$vm" --no-graphics >"/tmp/tart-$vm.log" 2>&1 &
  for _ in $(seq 1 90); do
    ip=$(tart ip "$vm" 2>/dev/null | grep -Eo '^[0-9]+(\.[0-9]+){3}$' || true)
    [ -n "$ip" ] && break
    running "$vm" || die "$vm stopped while booting: $(tail -n 1 "/tmp/tart-$vm.log")"
    sleep 2
  done
  [ -n "$ip" ] || die "$vm got no IP address"
  for _ in $(seq 1 60); do vmssh "$ip" true 2>/dev/null && break; sleep 1; done
  vmssh "$ip" "cd $GUEST_RUNNER && ./ac-runner service -c stop >/dev/null 2>&1 || true"
  IP=$ip
  log "$vm up at $ip, runner service stopped"
}

# halt <vm> <ip> <enable|keep>: enable the runner service for the next boot (or leave it stopped), power off.
halt() {
  local vm=$1 ip=$2 svc=$3
  [ "$svc" = enable ] && vmssh "$ip" 'sudo launchctl enable system/io.appcircle.runner'
  vmssh "$ip" 'sudo shutdown -h now' >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do running "$vm" || break; sleep 2; done
  if running "$vm"; then
    tart stop "$vm" >/dev/null 2>&1 || true
    pkill -f "tart run $vm( |\$)" || true
  fi
  log "$vm powered off"
}

# ------------------------------------------------------------------ images
cmd_images() {
  local v guest host runsh xcodes state
  printf '%-8s %-16s %-14s %-8s %-10s %s\n' IMAGE "GUEST MACOS" "HOST MACOS" RUN.SH STATE "XCODE (BUILD)"
  printf '%s\n' "$CATALOG" | while IFS='|' read -r v guest host runsh xcodes; do
    state="-"
    tart_has "macOS_$v" && state="installed"
    if [ "$host" = 26 ]; then host="Tahoe+"; else host="Sequoia+"; fi
    printf '%-8s %-16s %-14s %-8s %-10s %s\n' "$v" "$guest" "$host" "$runsh" "$state" "$xcodes"
  done
  printf '\nThis host: macOS %s, %s GB free. Images not listed: see the runner VM setup page.\n' \
    "$(sw_vers -productVersion)" "$(free_gb)"
}

expected_md5() {  # expected_md5 <file>: from <file>.md5, or the ETag at the default location
  local f=$1 sum=""
  sum=$(curl --netrc-optional -fsSL "$IMAGE_BASE/$f.md5" 2>/dev/null | awk 'NR==1 {print tolower($1)}' || true)
  if printf '%s' "$sum" | grep -Eq '^[0-9a-f]{32}$'; then printf '%s' "$sum"; return 0; fi
  if [ "$IMAGE_BASE" = "$DEFAULT_IMAGE_BASE" ]; then
    sum=$(curl -fsSIL "$IMAGE_BASE/$f" | tr -d '\r' | awk -F'"' 'tolower($1) ~ /^etag:/ {print $2}' | tail -n 1)
    printf '%s' "$sum" | grep -Eq '^[0-9a-f]{32}$' && { printf '%s' "$sum"; return 0; }
  fi
  return 1
}

remote_size_gb() {  # whole GB, rounded up
  local b
  b=$(curl --netrc-optional -fsSIL "$IMAGE_BASE/$1" | tr -d '\r' | awk 'tolower($1)=="content-length:" {print $2}' | tail -n 1)
  [ -n "$b" ] || { echo 0; return; }
  echo $(( (b + 1073741823) / 1073741824 ))
}

# fetch <file> <dest-dir> <stream:0|1>: download (resumable) and verify, then extract with -S.
# With stream=1 nothing is kept on disk: curl | tee md5 | pigz | tar, verified after extraction.
fetch() {
  local f=$1 dest=$2 stream=$3 want got tmp
  want=$(expected_md5 "$f") || die "no checksum for $f at $(masked "$IMAGE_BASE"): the location must serve $f.md5"
  mkdir -p "$dest"
  if [ "$stream" = 1 ]; then
    tmp=$(mktemp)
    log "streaming $f into $dest"
    curl --netrc-optional -fsSL --retry 5 --retry-delay 30 "$IMAGE_BASE/$f" \
      | tee >(md5 -q >"$tmp") | pigz -dc | tar -S -xf - -C "$dest" \
      || die "downloading or extracting $f failed; delete what it extracted in $dest and pull again"
    sleep 2; got=$(cat "$tmp"); rm -f "$tmp"
  else
    mkdir -p "$DOWNLOAD_DIR"
    log "downloading $f to $DOWNLOAD_DIR (resumes if interrupted)"
    curl --netrc-optional -fL --retry 5 --retry-delay 30 -C - -o "$DOWNLOAD_DIR/$f" "$IMAGE_BASE/$f"
    got=$(md5 -q "$DOWNLOAD_DIR/$f")
    [ "$got" = "$want" ] || die "$f is corrupt (md5 $got, expected $want). Delete $DOWNLOAD_DIR/$f and pull again."
    log "extracting $f"
    pigz -dc "$DOWNLOAD_DIR/$f" | tar -S -xf - -C "$dest"
  fi
  [ "$got" = "$want" ] || die "$f does not match its checksum (md5 $got, expected $want); delete what it extracted in $dest and pull again"
  ok "$f verified (md5 $got)"
}

runsh_cache() { echo "$HOME/.appcircle/run/run-$1.sh"; }

cmd_pull() {
  local v=${1:-} stream=0 runsh need_gb
  shift || true
  [ "${1:-}" = "--stream" ] && stream=1
  valid_version "$v" || die "usage: pull <image> [--stream]   (see: images)"
  runsh=$(catalog_field "$v" 4)
  [ -n "$runsh" ] || die "image $v is not in this tool's catalog; update runner-vm.sh or see the runner VM setup page"
  need pigz "brew install pigz"; need tart "brew install appcircleio/cli/tart"
  if [ "$(host_major)" -lt "$(catalog_field "$v" 3)" ]; then
    [ "${AC_RUNNER_ALLOW_OLD_HOST:-0}" = 1 ] \
      || die "image $v needs a macOS $(catalog_field "$v" 3) host or newer; this host runs $(sw_vers -productVersion) (upgrade the host first)"
    warn "image $v on a macOS $(sw_vers -productVersion) host is not supported (AC_RUNNER_ALLOW_OLD_HOST=1)"
  fi
  if tart_has "macOS_$v"; then
    log "macOS_$v is already installed"
  else
    need_gb=$(( $(remote_size_gb "macOS_$v.tar.gz") + $(remote_size_gb "xcodes_$v.tar.gz") ))
    [ "$stream" = 1 ] || need_gb=$(( need_gb * 2 ))
    need_gb=$(( need_gb + MIN_FREE_GB ))
    if [ "$(free_gb)" -lt "$need_gb" ]; then
      die "$(free_gb) GB free, about $need_gb GB needed$([ "$stream" = 1 ] || echo "; --stream needs about half (no archive kept, no resume)")"
    fi
    fetch "macOS_$v.tar.gz" "$HOME/.tart/vms/macOS_$v" "$stream"
    log "disk.img takes $(du -sh "$HOME/.tart/vms/macOS_$v/disk.img" | cut -f1) on disk"
  fi
  # Xcode disks: extract next to the others, never over a disk a running runner may have mounted.
  local stage="$IMAGES_DIR/.staging-$v" d moved=0
  mkdir -p "$IMAGES_DIR"
  get_runsh "$runsh"
  if pull_dmgs_present "$v"; then
    log "the Xcode disks of $v are in $IMAGES_DIR"
  else
    rm -rf "$stage"
    fetch "xcodes_$v.tar.gz" "$stage" "$stream"
    for d in "$stage"/*.dmg; do
      [ -f "$IMAGES_DIR/$(basename "$d")" ] && continue
      mv "$d" "$IMAGES_DIR/"; moved=$((moved + 1))
    done
    rm -rf "$stage"
    log "$moved new Xcode disk(s) in $IMAGES_DIR"
  fi
  pull_dmgs_present "$v" || die "an Xcode disk that run.sh $runsh mounts is missing in $IMAGES_DIR"
  [ "$stream" = 1 ] || rm -f "$DOWNLOAD_DIR/macOS_$v.tar.gz" "$DOWNLOAD_DIR/xcodes_$v.tar.gz"
  ok "image $v is ready: $(catalog_field "$v" 5)"
}

get_runsh() {
  local r=$1 f
  f=$(runsh_cache "$r")
  [ -s "$f" ] && return 0
  mkdir -p "$(dirname "$f")"
  curl --netrc-optional -fsSL -o "$f.tmp" "$IMAGE_BASE/run-$r.sh" || die "could not download run-$r.sh from $(masked "$IMAGE_BASE")"
  grep -q "^VERSION=\"$r\"" "$f.tmp" || die "run-$r.sh does not carry VERSION=\"$r\""
  chmod 755 "$f.tmp" && mv "$f.tmp" "$f"
  log "run.sh $r downloaded"
}

# The dmgs a run.sh mounts are the --disk lines of the run.sh paired with the image.
pull_dmgs_present() {
  local f d
  f=$(runsh_cache "$(catalog_field "$1" 4)")
  [ -s "$f" ] || return 1
  for d in $(grep -Eo 'xcode\.[0-9.]+\.dmg' "$f" | sort -u); do [ -f "$IMAGES_DIR/$d" ] || return 1; done
}

# ------------------------------------------------------------------ guest scripts
# Applied in a fresh clone of the image. Reads ~/ac-config (the folder without registrations),
# deletes it at the end. Exits non-zero when a trust URL does not verify.
guest_apply() {
  cat <<'EOF'
set -e
C=~/ac-config; R=/Volumes/agent-disk/appcircle-runner
source ~/.zshrc >/dev/null 2>&1 || true
envget() { local l; l=$(grep -E "^$1=" $C/host.env | tail -n 1); l=${l#*=}; l=${l#\"}; l=${l%\"}; print -r -- "$l"; }
lines() { [ -f "$1" ] && grep -v '^#' "$1" | grep -v '^[[:space:]]*$' || true; }
step() { print -r -- "  [$(date -u +%T)] $*"; }
cd $R
step "runner $(./ac-runner --version 2>/dev/null | tail -n 1)"
step "server settings"
jq --arg b "$(envget AC_BASE_API_URL)" --arg r "$(envget AC_REDIS_STREAM_ENDPOINT)" \
  '.ASPNETCORE_BASE_API_URL=$b | .ASPNETCORE_REDIS_STREAM_ENDPOINT=$r | .ASPNETCORE_NOSHUTDOWN="false"' \
  appsettings.json >appsettings.json.new && mv appsettings.json.new appsettings.json
args=()
for c in $C/certs/*.pem(N) $C/certs/*.crt(N); do args+=(--cert $c); done
for u in ${(f)"$(lines $C/trust-urls.txt)"}; do args+=(--url $u); done
if (( ${#args} )); then
  icv=$(./scripts/install_cert.sh --version 2>/dev/null | awk '{print $2}')
  case "$icv" in
    2.*|[3-9].*) ;;
    *) print -r -- "the runner in this image has install_cert.sh ${icv:-1.x}; certificates need 2.0 or newer (runner 1.9.3, image 261102 or newer)"; exit 1 ;;
  esac
  step "certificates (install_cert.sh $icv)"
  rc=0; ./scripts/install_cert.sh "${args[@]}" >/tmp/install_cert.log 2>&1 || rc=$?
  grep -E '^\[(WARN|ERROR)\]|Keychain: trusted|Verified' /tmp/install_cert.log | sed 's/^/    /' || true
  [ $rc = 0 ] || { cat /tmp/install_cert.log; print -r -- "install_cert.sh failed (exit $rc)"; exit 1; }
fi
ntp=$(envget NTP_SERVER)
if [ -n "$ntp" ]; then
  step "NTP $ntp"
  # configure_ntp.sh (runner package) syncs with sntp, writes /etc/ntp.conf and sets the time server,
  # then starts the runner service again: stop it at once, this VM has no registration yet.
  if [ -x ./scripts/configure_ntp.sh ]; then
    rc=0; ./scripts/configure_ntp.sh "$ntp" >/tmp/ntp.log 2>&1 || rc=$?
    ./ac-runner service -c stop >/dev/null 2>&1 || true
    [ $rc = 0 ] || { tail -n 20 /tmp/ntp.log; print -r -- "NTP server $ntp is not reachable from the VM"; exit 1; }
  else
    sudo systemsetup -setnetworktimeserver "$ntp" >/dev/null 2>&1 || true
  fi
fi
php=$(envget PROXY_HOSTPORT); np=$(envget NO_PROXY); [ -n "$np" ] || np="localhost,127.0.0.1"
if [ -n "$php" ]; then
  pu=$(envget PROXY_USER); pp=$(envget PROXY_PASSWORD)
  mkdir -p ~/.zshrc.d ~/.gradle
  if [ -n "$pu" ]; then
    # Basic-auth proxy: Java tools cannot send its credentials, so a local tinyproxy holds them.
    step "proxy: local tinyproxy on 127.0.0.1:8888 -> $php"
    eu=$(jq -rn --arg v "$pu" '$v|@uri'); ep=$(jq -rn --arg v "$pp" '$v|@uri')
    HTTPS_PROXY="http://$eu:$ep@$php" HTTP_PROXY="http://$eu:$ep@$php" brew install --quiet tinyproxy >/dev/null
    conf=/opt/homebrew/etc/tinyproxy/appcircle.conf
    printf 'User nobody\nGroup nobody\nPort 8888\nListen 127.0.0.1\nAllow 127.0.0.1\nTimeout 600\nMaxClients 100\nLogLevel Warning\nUpstream http %s:%s@%s\n' "$pu" "$pp" "$php" | sudo tee $conf >/dev/null
    sudo chown root:wheel $conf; sudo chmod 600 $conf
    pl=/Library/LaunchDaemons/io.appcircle.tinyproxy.plist
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>\n<key>Label</key><string>io.appcircle.tinyproxy</string>\n<key>ProgramArguments</key><array><string>/opt/homebrew/bin/tinyproxy</string><string>-d</string><string>-c</string><string>%s</string></array>\n<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>\n</dict></plist>\n' "$conf" | sudo tee $pl >/dev/null
    sudo chown root:wheel $pl; sudo chmod 644 $pl
    sudo launchctl bootout system/io.appcircle.tinyproxy 2>/dev/null || true
    sudo launchctl bootstrap system $pl
    for i in {1..20}; do nc -z 127.0.0.1 8888 2>/dev/null && break; sleep 1; done
    L=http://127.0.0.1:8888; ph=127.0.0.1; pport=8888
  else
    step "proxy: $php"
    L="http://$php"; ph=${php%:*}; pport=${php##*:}
  fi
  print -r -- "# Written by runner-vm.sh from host.env; edit there, not here.
export HTTP_PROXY=$L HTTPS_PROXY=$L http_proxy=$L https_proxy=$L NO_PROXY=\"$np\" no_proxy=\"$np\"" >~/.zshrc.d/00-proxy.zsh
  jnp=$(print -r -- "$np" | tr ',' '\n' | grep -v / | grep -v '^$' | sed 's/^\./*./' | paste -sd'|' -)
  { for s in http https; do print -r -- "systemProp.$s.proxyHost=$ph"; print -r -- "systemProp.$s.proxyPort=$pport"; print -r -- "systemProp.$s.nonProxyHosts=$jnp"; done } >~/.gradle/gradle.properties
  export HTTP_PROXY=$L HTTPS_PROXY=$L http_proxy=$L https_proxy=$L NO_PROXY=$np no_proxy=$np
fi
if [ -s $C/hosts ]; then
  step "hosts"
  while IFS= read -r l; do [ -n "$l" ] && { grep -qxF -- "$l" /etc/hosts || print -r -- "$l" | sudo tee -a /etc/hosts >/dev/null; }; done <$C/hosts
fi
if [ -d $C/files ] && [ -n "$(ls -A $C/files 2>/dev/null)" ]; then step "files"; rsync -a $C/files/ ~/; fi
grep -q 'zshrc.d' ~/.zshrc || print -r -- $'\n# Customer settings from the runner host config (runner-vm.sh)\nfor f in ~/.zshrc.d/*.zsh(N); do source $f; done' >>~/.zshrc
for f in ~/.zshrc.d/*.zsh(N); do source $f; done
while read -r kind a b c; do
  case "$kind" in
    brew) step "tool: brew $a"; brew install --quiet "$a" >/dev/null ;;
    url) step "tool: $a"
         curl -fsSL -o /tmp/tool.dl "$a"
         print -r -- "$b  /tmp/tool.dl" | shasum -a 256 -c - >/dev/null || { print -r -- "checksum mismatch for $a"; exit 1; }
         case "$a" in
           *.zip) sudo mkdir -p "$c"; sudo unzip -o -q /tmp/tool.dl -d "$c" ;;
           *.tar.gz|*.tgz) sudo mkdir -p "$c"; sudo tar -xzf /tmp/tool.dl -C "$c" ;;
           *) sudo mkdir -p "$(dirname "$c")"; sudo install -m 755 /tmp/tool.dl "$c" ;;
         esac
         rm -f /tmp/tool.dl ;;
    "") ;;
    *) print -r -- "unknown line in tools.txt: $kind"; exit 1 ;;
  esac
done < <(lines $C/tools.txt)
for p in ${(f)"$(lines $C/android-sdk.txt)"}; do step "android: $p"; yes | sdkmanager --install "$p" >/dev/null; done
for s in $C/scripts/*.sh(N); do step "script: ${s:t}"; bash $s; done
step "verify"
fail=0
for u in ${(f)"$(lines $C/trust-urls.txt)"}; do
  h=${u%%:*}; p=${u##*:}; [ "$p" = "$u" ] && p=443
  v=$(/usr/bin/curl -s -o /dev/null --max-time 20 -w '%{ssl_verify_result}' "https://$h:$p/" || true)
  print -r -- "    https://$h:$p verify=$v"; [ "$v" = 0 ] || fail=1
done
rm -rf $C
[ $fail = 0 ] || exit 1
print -r -- "runner-vm: applied"
EOF
}

# Reads what a base VM holds that its image does not. Prints a tar stream on stdout.
guest_collect() {
  cat <<'EOF'
set +e
D=$(mktemp -d); cd $D; R=/Volumes/agent-disk/appcircle-runner
source ~/.zshrc >/dev/null 2>&1
cp $R/selfHosted.json . 2>/dev/null
jq -S . $R/appsettings.json >appsettings.json 2>/dev/null
security find-certificate -a -p /Library/Keychains/System.keychain >keychain.pem 2>/dev/null
# The public roots macOS and OpenSSL ship: never a customer's (the Node bundle repeats them).
{ security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain; cat /etc/ssl/cert.pem; } >public.pem 2>/dev/null
for j in ~/.sdkman/candidates/java/*(N/); do
  [ "${j:t}" = current ] && continue
  ks=$j/lib/security/cacerts; [ -f $ks ] || ks=$j/jre/lib/security/cacerts
  $j/bin/keytool -list -rfc -keystore $ks -storepass changeit 2>/dev/null | sed -n '/BEGIN CERT/,/END CERT/p'
done >jdk.pem
[ -f ~/cacerts.crt ] && cp ~/cacerts.crt node.pem
sed -n 's/^server //p' /etc/ntp.conf >ntp.txt 2>/dev/null
cp /etc/hosts hosts; cp ~/.zshrc zshrc 2>/dev/null
mkdir dot
for f in .npmrc .yarnrc .yarnrc.yml .gemrc .bundle/config .config/pip/pip.conf .pip/pip.conf .gradle/gradle.properties \
         .m2/settings.xml .netrc .curlrc .gitconfig .ssh/config .cocoapods/config.yaml; do
  [ -f ~/$f ] && { mkdir -p dot/${f:h}; cp ~/$f dot/$f; }
done
ls ~/.gradle/init.d 2>/dev/null | sed 's#^#.gradle/init.d/#' >gradle-init.txt
/opt/homebrew/bin/brew leaves 2>/dev/null >brew-leaves.txt
/opt/homebrew/bin/brew tap 2>/dev/null >brew-taps.txt
gem list --no-versions 2>/dev/null | sort >gems.txt
(cd "$ANDROID_HOME" 2>/dev/null && find platforms build-tools ndk cmake -mindepth 1 -maxdepth 1 2>/dev/null | sort) >android.txt
ls /usr/local/bin /opt 2>/dev/null | sort >bins.txt
ls /Library/LaunchDaemons /Library/LaunchAgents ~/Library/LaunchAgents 2>/dev/null | sort >launchd.txt
scutil --proxy 2>/dev/null | grep -E 'Enable|Proxy|Port' >proxy.txt
grep -a -E 'install_cert|keytool|add-trusted-cert|sdkmanager|brew install|gem install|npm (config|install -g)|pip install|configure_ntp|/etc/hosts|curl .*-o' ~/.zsh_history 2>/dev/null | sed 's/^: [0-9]*:[0-9]*;//' | sort -u >history.txt
tar -cf - .
EOF
}

# ------------------------------------------------------------------ capture
split_pem() {
  mkdir -p "$2"
  awk -v d="$2" '/BEGIN CERT/{n++; f=sprintf("%s/%04d.pem", d, n)} f{print > f} /END CERT/{close(f); f=""}' "$1"
}
fingerprints() { local f; for f in "$1"/*.pem; do [ -f "$f" ] && openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null; done | sort -u; }

collect() {  # collect <vm> <outdir>: from a copy, so the original VM is never booted or changed
  local vm=$1 out=$2 copy="ac-capture-$1"
  tart delete "$copy" >/dev/null 2>&1 || true
  tart clone "$vm" "$copy"
  boot "$copy"
  mkdir -p "$out"
  # The script goes in as a file and runs with stdin closed: a command in it that reads stdin
  # would otherwise swallow the rest of the script.
  guest_collect | vmssh_in "$IP" 'cat >/tmp/ac-collect.zsh'
  vmssh "$IP" 'zsh /tmp/ac-collect.zsh' | tar -xf - -C "$out"
  halt "$copy" "$IP" keep
  tart delete "$copy"
}

cmd_capture() {
  local vm=${1:-} img=${2:-} W name fp subj iss cn h n=0
  [ -n "$vm" ] && [ -n "$img" ] || die "usage: capture <existing base VM> <the image it was made from, e.g. macOS_260723>"
  tart_has "$vm" || die "VM $vm not found (tart list)"
  tart_has "$img" || die "image $img not found (tart list); capture compares the VM with its source image"
  lock; start_log capture
  W=$(mktemp -d /tmp/ac-capture.XXXXXX)
  mkdir -p "$CFG"/{runners,certs,review,files,scripts}
  log "reading the image $img (what the VM started from)"; collect "$img" "$W/img"
  log "reading the VM $vm"; collect "$vm" "$W/vm"

  if [ -s "$W/vm/selfHosted.json" ]; then
    name=$(jq -r .AgentName "$W/vm/selfHosted.json")
    mkdir -p "$CFG/runners/$name"
    cp "$W/vm/selfHosted.json" "$CFG/runners/$name/selfHosted.json"
    log "registration: $(jq -c 'del(.QueueToken)' "$W/vm/selfHosted.json") -> runners/$name (the VM is named $name from now on)"
  else
    warn "$vm has no registration; register the runner after create"
  fi
  if [ ! -f "$CFG/host.env" ]; then
    {
      echo "# Runner host settings, written by capture on $(date '+%F'). KEY=VALUE, one per line; quotes optional."
      echo "AC_BASE_API_URL=$(jq -r '.ASPNETCORE_BASE_API_URL // empty' "$W/vm/appsettings.json")"
      echo "AC_REDIS_STREAM_ENDPOINT=$(jq -r '.ASPNETCORE_REDIS_STREAM_ENDPOINT // empty' "$W/vm/appsettings.json")"
      echo "VM_CPU=$(jq -r .cpuCount "$HOME/.tart/vms/$vm/config.json")"
      echo "VM_MEMORY_MB=$(( $(jq -r .memorySize "$HOME/.tart/vms/$vm/config.json") / 1048576 ))"
      echo "NTP_SERVER=$(cmp -s "$W/img/ntp.txt" "$W/vm/ntp.txt" || head -n 1 "$W/vm/ntp.txt")"
      echo "# Corporate proxy: PROXY_HOSTPORT=host:port, PROXY_USER, PROXY_PASSWORD (a local proxy in the VM holds them), NO_PROXY"
      echo "PROXY_HOSTPORT="
      echo "PROXY_USER="
      echo "PROXY_PASSWORD="
      echo "NO_PROXY=localhost,127.0.0.1"
    } >"$CFG/host.env"
  else
    log "host.env exists, left as it is"
  fi

  # Certificates: roots to certs/, other certificates become trust URLs (their names) for review.
  cat "$W/vm/keychain.pem" "$W/vm/jdk.pem" "$W/vm/node.pem" 2>/dev/null >"$W/vm-all.pem" || true
  cat "$W/img/keychain.pem" "$W/img/jdk.pem" "$W/img/node.pem" "$W/img/public.pem" "$W/vm/public.pem" 2>/dev/null >"$W/img-all.pem" || true
  split_pem "$W/vm-all.pem" "$W/vmc"; split_pem "$W/img-all.pem" "$W/imgc"
  local known; known=$(fingerprints "$W/imgc")
  : >"$CFG/review/certificates.txt"
  for f in "$W"/vmc/*.pem; do
    [ -f "$f" ] || continue
    fp=$(openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null) || continue
    case $'\n'"$known"$'\n' in *$'\n'"$fp"$'\n'*) continue ;; esac
    known="$known"$'\n'"$fp"
    subj=$(openssl x509 -in "$f" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')
    iss=$(openssl x509 -in "$f" -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//')
    cn=$(printf '%s' "$subj" | sed -n 's/.*CN=\([^,]*\).*/\1/p' | tr -c 'A-Za-z0-9.-' '_')
    if [ "$subj" = "$iss" ]; then
      cp "$f" "$CFG/certs/${cn:-root-$n}.pem"; n=$((n + 1)); log "root certificate: $subj"
    else
      echo "$subj  $(openssl x509 -in "$f" -noout -ext subjectAltName 2>/dev/null | grep -o 'DNS:[^,]*' | tr '\n' ' ')" >>"$CFG/review/certificates.txt"
    fi
  done
  [ -f "$CFG/trust-urls.txt" ] || printf '# One host[:port] per line: every host the builds reach (Appcircle API, Redis, Git, proxy, mirrors).\n' >"$CFG/trust-urls.txt"
  for h in $(url_host "$(env_get AC_BASE_API_URL)") $(env_get AC_REDIS_STREAM_ENDPOINT | cut -d, -f1) \
           $(grep -o 'DNS:[^ ]*' "$CFG/review/certificates.txt" | sed 's/DNS://' | grep -v '\*' || true); do
    [ -n "$h" ] && { grep -qxF "$h" "$CFG/trust-urls.txt" || echo "$h" >>"$CFG/trust-urls.txt"; }
  done
  grep -q '\*\.' "$CFG/review/certificates.txt" 2>/dev/null && warn "a wildcard certificate is trusted in $vm: add one host under it that builds reach to trust-urls.txt (see review/certificates.txt)"

  # Everything else needs a person once: hosts lines go straight in, the rest to review/.
  comm -13 <(sort -u "$W/img/hosts") <(sort -u "$W/vm/hosts") | grep -v '^#' | grep -v '^$' >"$CFG/hosts" || true
  comm -13 <(sort -u "$W/img/zshrc") <(sort -u "$W/vm/zshrc") | grep -v 'NODE_EXTRA_CA_CERTS' >"$CFG/review/zshrc-lines.txt" || true
  comm -13 "$W/img/brew-leaves.txt" "$W/vm/brew-leaves.txt" | sed 's/^/brew /' >"$CFG/review/tools.txt" || true
  comm -13 "$W/img/brew-taps.txt" "$W/vm/brew-taps.txt" | sed 's/^/# tap: /' >>"$CFG/review/tools.txt" || true
  comm -13 "$W/img/gems.txt" "$W/vm/gems.txt" | sed 's/^/# gem: /' >>"$CFG/review/tools.txt" || true
  comm -13 "$W/img/bins.txt" "$W/vm/bins.txt" | sed 's/^/# file in \/usr\/local\/bin or \/opt: /' >>"$CFG/review/tools.txt" || true
  comm -13 "$W/img/android.txt" "$W/vm/android.txt" | sed -E 's#^([^/]+)/(.*)#\1;\2#' >"$CFG/review/android-sdk.txt" || true
  comm -13 "$W/img/launchd.txt" "$W/vm/launchd.txt" >"$CFG/review/launchd.txt" || true
  diff <(jq -S 'del(.ASPNETCORE_BASE_API_URL, .ASPNETCORE_REDIS_STREAM_ENDPOINT)' "$W/img/appsettings.json") \
       <(jq -S 'del(.ASPNETCORE_BASE_API_URL, .ASPNETCORE_REDIS_STREAM_ENDPOINT)' "$W/vm/appsettings.json") >"$CFG/review/appsettings.diff" || true
  (cd "$W/vm/dot" && find . -type f | sed 's#^\./##') | while read -r f; do
    cmp -s "$W/img/dot/$f" "$W/vm/dot/$f" && continue
    mkdir -p "$CFG/review/files/$(dirname "$f")"; cp "$W/vm/dot/$f" "$CFG/review/files/$f"
  done
  comm -13 "$W/img/gradle-init.txt" "$W/vm/gradle-init.txt" >>"$CFG/review/launchd.txt" 2>/dev/null || true
  cp "$W/vm/proxy.txt" "$CFG/review/system-proxy.txt"; cp "$W/vm/history.txt" "$CFG/review/history.txt"
  rm -rf "$W"
  chmod -R go-rwx "$CFG"
  for f in "$CFG"/review/*.txt "$CFG"/review/*.diff; do [ -s "$f" ] || rm -f "$f"; done
  ok "capture done: $CFG"
  log "review once, then the folder is the only place to change a runner:"
  ls "$CFG/review" 2>/dev/null | sed 's/^/    review\//'
  log "  files in review/files/: move what the runners need to files/ (they may hold credentials)"
  log "  review/tools.txt and review/android-sdk.txt: copy the lines you need to tools.txt and android-sdk.txt"
}

# ------------------------------------------------------------------ create
apply_folder() {  # apply_folder <ip>
  local ip=$1 t
  t=$(mktemp -d /tmp/ac-apply.XXXXXX)
  mkdir "$t/ac-config"
  (cd "$CFG" && tar -cf - --exclude runners --exclude review --exclude logs --exclude .lock .) | tar -xf - -C "$t/ac-config"
  guest_apply >"$t/ac-config/apply.zsh"
  vmssh "$ip" 'rm -rf ~/ac-config'
  vmscp "$t/ac-config" "$GUEST_USER@$ip:"
  rm -rf "$t"
  # Run as a file with stdin closed (vmssh), and require the last line: a script cut short
  # (a command that ate its input, a dropped session) must never pass as applied.
  local out
  out=$(mktemp)
  vmssh "$ip" 'zsh ~/ac-config/apply.zsh' | tee "$out"
  if ! tail -n 1 "$out" | grep -qx 'runner-vm: applied'; then rm -f "$out"; return 1; fi
  rm -f "$out"
}

check_folder() {
  [ -f "$CFG/host.env" ] || die "$CFG/host.env missing: run capture first, or copy the template from the docs"
  [ -n "$(env_get AC_BASE_API_URL)" ] || die "AC_BASE_API_URL is empty in $CFG/host.env"
  [ -n "$(env_get VM_CPU)" ] && [ -n "$(env_get VM_MEMORY_MB)" ] || die "VM_CPU and VM_MEMORY_MB are required in $CFG/host.env"
}

runner_dir() { echo "$RUNNERS_ROOT/$1"; }

# create_vms <image version> <name>...: one base from the image + folder, then one VM per runner
create_vms() {
  local v=$1; shift
  local img="macOS_$v" n t0 t1 runsh
  t0=$(date +%s)
  for n in "$@"; do valid_name "$n" || die "runner name '$n': 5-24 letters, digits, - or _"; done
  tart_has "$img" || die "$img is not installed: run pull $v"
  runsh=$(catalog_field "$v" 4)
  get_runsh "$runsh"
  pull_dmgs_present "$v" || die "Xcode disks of $v missing in $IMAGES_DIR: run pull $v"
  [ "$(free_gb)" -ge "$MIN_FREE_GB" ] || die "less than $MIN_FREE_GB GB free"
  if running "$BASE_VM"; then tart stop "$BASE_VM" >/dev/null 2>&1 || true; pkill -f "tart run $BASE_VM( |\$)" || true; sleep 2; fi
  tart delete "$BASE_VM" >/dev/null 2>&1 || true
  tart clone "$img" "$BASE_VM"
  tart set "$BASE_VM" --cpu "$(env_get VM_CPU)" --memory "$(env_get VM_MEMORY_MB)"
  boot "$BASE_VM"
  log "applying $CFG"
  if ! apply_folder "$IP"; then
    halt "$BASE_VM" "$IP" keep; tart delete "$BASE_VM"
    die "applying the folder failed (see above); nothing was changed on the runners"
  fi
  halt "$BASE_VM" "$IP" keep
  log "base ready in $(( $(date +%s) - t0 )) s"
  for n in "$@"; do
    t1=$(date +%s)
    if tart_has "$n"; then
      tart delete "$n-prev" >/dev/null 2>&1 || true
      tart rename "$n" "$n-prev"
      log "$n kept as $n-prev (rollback)"
    fi
    tart clone "$BASE_VM" "$n"
    if [ -f "$CFG/runners/$n/selfHosted.json" ]; then
      boot "$n"
      vmscp "$CFG/runners/$n/selfHosted.json" "$GUEST_USER@$IP:$GUEST_RUNNER/selfHosted.json"
      vmssh "$IP" "chmod 600 $GUEST_RUNNER/selfHosted.json"
      halt "$n" "$IP" enable
      log "$n: registration $(jq -c '{AgentName, PoolName}' "$CFG/runners/$n/selfHosted.json")"
    else
      [ "${REGISTER_NEXT:-0}" = 1 ] || warn "$n has no registration yet: run register $n <pool>"
    fi
    mkdir -p "$(runner_dir "$n")"
    [ -f "$(runner_dir "$n")/run.sh" ] && cp -p "$(runner_dir "$n")/run.sh" "$(runner_dir "$n")/run.sh.prev"
    cp "$(runsh_cache "$runsh")" "$(runner_dir "$n")/run.sh"; chmod u+x "$(runner_dir "$n")/run.sh"
    rm -f "$(runner_dir "$n")/.stop" "$(runner_dir "$n")/.stopped"
    ok "$n ready in $(( $(date +%s) - t1 )) s (image $v, run.sh $runsh)"
  done
  tart delete "$BASE_VM"
  log "created in $(( $(date +%s) - t0 )) s"
}

cmd_create() {
  local v=${1:-}; shift || true
  valid_version "$v" && [ $# -ge 1 ] || die "usage: create <image> <name>..."
  check_folder; lock; start_log create
  create_vms "$v" "$@"
  log "next: start $*"
}

# ------------------------------------------------------------------ register
read_token() {
  local t=""
  if [ -n "${AC_RUNNER_TOKEN_FILE:-}" ]; then t=$(cat "$AC_RUNNER_TOKEN_FILE")
  elif [ ! -t 0 ]; then t=$(cat)
  else printf 'Runner access token (Self-hosted Runners page): ' >&2; read -rs t; echo >&2; fi
  t=$(printf '%s' "$t" | tr -d '[:space:]')
  [ -n "$t" ] || die "no runner access token"
  TOKEN=$t
}

register_one() {  # register_one <name> <pool>
  local n=$1 pool=$2
  tart_has "$n" || die "VM $n not found: run create first"
  [ -f "$CFG/runners/$n/selfHosted.json" ] && die "$n is registered already (runners/$n); the server rejects a second runner with the same name"
  running "$n" && die "$n is running; stop it first"
  boot "$n"
  printf '%s' "$TOKEN" | vmssh_in "$IP" "cd $GUEST_RUNNER && rm -f selfHosted.json && T=\$(cat) && ./ac-runner register -t \"\$T\" -n '$n' -p '$pool' && jq '.OsValues=[\"ios\",\"android\"]' selfHosted.json >s.tmp && mv s.tmp selfHosted.json" \
    || { halt "$n" "$IP" keep; die "registration of $n failed (token, name taken on the server, or the server is not reachable)"; }
  mkdir -p "$CFG/runners/$n" && chmod 700 "$CFG/runners" "$CFG/runners/$n"
  vmscp "$GUEST_USER@$IP:$GUEST_RUNNER/selfHosted.json" "$CFG/runners/$n/selfHosted.json"
  chmod 600 "$CFG/runners/$n/selfHosted.json"
  halt "$n" "$IP" enable
  ok "$n registered in pool $pool"
}

cmd_register() {
  local n=${1:-} pool=${2:-}
  [ -n "$n" ] && [ -n "$pool" ] || die "usage: register <name> <pool>   (runner access token on stdin, or AC_RUNNER_TOKEN_FILE)"
  valid_name "$pool" || die "pool name '$pool': 5-24 letters, digits, - or _"
  read_token; lock; start_log register
  register_one "$n" "$pool"
}

# ------------------------------------------------------------------ service
service_script() {  # the runner-service.sh next to run.sh; downloaded once, kept for later runs
  local d; d=$(runner_dir "$1")
  if [ ! -x "$d/runner-service.sh" ]; then
    curl -fsSL -o "$d/runner-service.sh" "$CDN_BASE/runner-service.sh" || die "could not download runner-service.sh from $(masked "$CDN_BASE")"
    chmod u+x "$d/runner-service.sh"
  fi
  echo "$d/runner-service.sh"
}

sudo_ok() { sudo -n true 2>/dev/null || { [ -t 0 ] && sudo -v; }; }

start_one() {
  local n=$1 s net
  [ -x "$(runner_dir "$n")/run.sh" ] || die "$(runner_dir "$n")/run.sh missing: run create first"
  tart_has "$n" || die "VM $n not found"
  s=$(service_script "$n")
  sudo_ok || die "starting the service needs sudo"
  net="$(url_host "$(env_get AC_BASE_API_URL)"):443"
  # runner-service.sh 1.0.1 and newer take the host run.sh waits for at boot; 1.0.0 does not.
  if "$s" --help 2>&1 | grep -q -- '--net-check-host'; then
    (cd "$(runner_dir "$n")" && sudo ./runner-service.sh install "$n" --net-check-host "$net")
  else
    (cd "$(runner_dir "$n")" && sudo ./runner-service.sh install "$n")
  fi
  ok "$n started as a launchd service"
}

stop_one() {  # stops the service, or a run.sh loop started by hand, and the current clone
  local n=$1 d pids c ip
  d=$(runner_dir "$n")
  if [ -f "/Library/LaunchDaemons/io.appcircle.$n.plist" ]; then
    sudo_ok || die "stopping the service needs sudo"
    (cd "$d" && sudo ./runner-service.sh stop --now) || true
  fi
  pids=$(pgrep -f "$d/run.sh|\./run.sh $n\$" 2>/dev/null || true)
  if [ -n "$pids" ]; then
    touch "$d/.stop"
    askpass
    for c in $(tart list 2>/dev/null | awk -v p="^$n-[0-9a-f]{8}-" '$2 ~ p {print $2}'); do
      ip=$(tart ip "$c" 2>/dev/null || true)
      [ -n "$ip" ] && vmssh "$ip" 'sudo shutdown -h now' >/dev/null 2>&1 || true
    done
    for c in $(seq 1 60); do pgrep -f "$d/run.sh|\./run.sh $n\$" >/dev/null 2>&1 || break; sleep 3; done
  fi
  for c in $(tart list 2>/dev/null | awk -v p="^$n-[0-9a-f]{8}-" '$2 ~ p {print $2}'); do
    tart stop "$c" >/dev/null 2>&1 || true; tart delete "$c" >/dev/null 2>&1 || true
  done
  log "$n stopped"
}

names_or_all() {
  if [ $# -gt 0 ]; then printf '%s\n' "$@"; return; fi
  ls "$CFG/runners" 2>/dev/null || true
}

cmd_start() { local n; check_folder; for n in $(names_or_all "$@"); do start_one "$n"; done; }
cmd_stop() { local n; for n in $(names_or_all "$@"); do stop_one "$n"; done; }

cmd_status() {
  local n d svc vm prev clone runsh
  printf '%-24s %-8s %-9s %-10s %-8s %s\n' RUNNER VM ROLLBACK SERVICE RUN.SH "CURRENT CLONE"
  for n in $(names_or_all "$@"); do
    d=$(runner_dir "$n")
    vm="-"; tart_has "$n" && vm="yes"
    prev="-"; tart_has "$n-prev" && prev="$n-prev"
    svc="-"
    if [ -f "/Library/LaunchDaemons/io.appcircle.$n.plist" ]; then
      svc="installed"; launchctl print "system/io.appcircle.$n" >/dev/null 2>&1 && svc="running"
    fi
    runsh=$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$d/run.sh" 2>/dev/null | head -n 1)
    clone=$(tart list 2>/dev/null | awk -v p="^$n-[0-9a-f]{8}-" '$2 ~ p {print $2}' | head -n 1)
    [ "$prev" != "-" ] && prev="yes"
    printf '%-24s %-8s %-9s %-10s %-8s %s\n' "$n" "$vm" "$prev" "$svc" "${runsh:--}" "${clone:--}"
  done
  printf '\nImages: %s\n' "$(tart list 2>/dev/null | awk 'NR>1 && $2 ~ /^macOS_[0-9]+$/ {printf "%s ", $2}')"
  printf 'Free disk: %s GB. Folder: %s\n' "$(free_gb)" "$CFG"
}

# ------------------------------------------------------------------ install / upgrade / rollback
cmd_install() {
  local v=${1:-} pool=${2:-} n
  shift 2 || true
  valid_version "$v" && [ -n "$pool" ] && [ $# -ge 1 ] || die "usage: install <image> <pool> <name>...   (token on stdin)"
  valid_name "$pool" || die "pool name '$pool': 5-24 letters, digits, - or _"
  for n in "$@"; do
    valid_name "$n" || die "runner name '$n': 5-24 letters, digits, - or _"
    [ -f "$CFG/runners/$n/selfHosted.json" ] && die "$n is registered already; use upgrade"
  done
  check_folder; read_token; lock; start_log install
  tart_has "macOS_$v" || cmd_pull "$v"
  REGISTER_NEXT=1 create_vms "$v" "$@"
  for n in "$@"; do register_one "$n" "$pool"; done
  for n in "$@"; do start_one "$n"; done
  ok "installed: $*  (status: ./runner-vm.sh status)"
}

cmd_upgrade() {
  local v=${1:-} n
  shift || true
  valid_version "$v" || die "usage: upgrade <image> [<name>...]   (default: every runner in $CFG/runners)"
  # shellcheck disable=SC2046 # runner names hold no spaces (5-24 letters, digits, - or _)
  set -- $(names_or_all "$@")
  [ $# -ge 1 ] || die "no runners in $CFG/runners: run capture on the current VMs first"
  for n in "$@"; do [ -f "$CFG/runners/$n/selfHosted.json" ] || die "no registration for $n in $CFG/runners: run capture first"; done
  check_folder; lock; start_log upgrade
  tart_has "macOS_$v" || cmd_pull "$v"
  log "stopping $*"
  for n in "$@"; do stop_one "$n"; done
  if ! (create_vms "$v" "$@"); then
    warn "create failed; starting the runners again on what they had"
    for n in "$@"; do start_one "$n" || true; done
    exit 1
  fi
  for n in "$@"; do start_one "$n"; done
  ok "upgraded to $v: $*  (rollback: ./runner-vm.sh rollback $*)"
}

cmd_rollback() {
  local n d
  [ $# -ge 1 ] || die "usage: rollback <name>..."
  for n in "$@"; do tart_has "$n-prev" || die "$n-prev not found: nothing to roll back to"; done
  lock; start_log rollback
  for n in "$@"; do
    d=$(runner_dir "$n")
    stop_one "$n"
    tart delete "$n"; tart rename "$n-prev" "$n"
    [ -f "$d/run.sh.prev" ] && mv "$d/run.sh.prev" "$d/run.sh"
    start_one "$n"
    ok "$n rolled back"
  done
}

cmd_init() {  # first install: the folder with a commented host.env to fill in
  [ -f "$CFG/host.env" ] && die "$CFG/host.env exists already"
  mkdir -p "$CFG"/{runners,certs,files,scripts} && chmod 700 "$CFG"
  cat >"$CFG/host.env" <<'EOF'
# Runner host settings. KEY=VALUE, one per line; quotes are optional. Read by runner-vm.sh, never executed.
# Your Appcircle server (build API URL and Redis endpoint, as in the runner setup docs):
AC_BASE_API_URL=https://api.appcircle.example.com/build/v1
AC_REDIS_STREAM_ENDPOINT=redis.appcircle.example.com:443,ssl=true
# Each runner VM. The host's memory and cores are shared by all runners on it.
VM_CPU=4
VM_MEMORY_MB=8192
# Your NTP server, when the VMs cannot reach Apple's (leave empty otherwise):
NTP_SERVER=
# Corporate proxy, when the VMs reach the internet only through it. With PROXY_USER set, a local
# proxy in each VM holds the credentials and every tool uses it without them.
PROXY_HOSTPORT=
PROXY_USER=
PROXY_PASSWORD=
NO_PROXY=localhost,127.0.0.1
EOF
  printf '# One host[:port] per line: every host the builds reach over HTTPS (Appcircle API, Redis, Git, proxy, mirrors).\n' >"$CFG/trust-urls.txt"
  printf '# brew <formula>   or   url <https URL> <sha256> <install dir, or file path for a single binary>\n' >"$CFG/tools.txt"
  printf '# sdkmanager package ids, one per line, for packages the image does not have\n' >"$CFG/android-sdk.txt"
  chmod -R go-rwx "$CFG"
  ok "created $CFG"
  log "next: edit host.env, put your private root CAs (.pem) in certs/ and your hosts in trust-urls.txt, then:"
  log "  ./runner-vm.sh install <image> <pool> <name>...   (./runner-vm.sh images lists the images)"
}

cmd_doctor() {
  local v
  printf 'macOS %s (%s), Tart %s, %s GB free\n' "$(sw_vers -productVersion)" "$(uname -m)" "$(tart --version 2>/dev/null || echo missing)" "$(free_gb)"
  [ "$(uname -m)" = arm64 ] || echo "FAIL Apple silicon is required"
  for v in tart pigz jq ssh curl openssl; do command -v $v >/dev/null 2>&1 || echo "FAIL $v missing"; done
  brew info appcircleio/cli/tart >/dev/null 2>&1 || echo "WARN tart should come from the appcircleio/cli tap"
  [ "$(free_gb)" -ge 150 ] || echo "WARN under 150 GB free: an image upgrade needs about 150 GB with --stream, 290 GB without"
  pmset -g | awk '$1=="sleep" && $2!=0 {print "WARN the host sleeps (sudo pmset -a sleep 0)"}'
  [ -f "$CFG/host.env" ] && echo "OK   folder $CFG" || echo "INFO no folder yet: capture (upgrade) or write host.env (first install)"
  echo "For a full host check: curl -fsSL $CDN_BASE/check-runner-host.sh | bash"
}

usage() {
  cat <<EOF
runner-vm.sh $VERSION - Appcircle macOS runner VMs on this host

Images
  images                          image versions, their Xcode versions and what is installed here
  pull <image> [--stream]         download, verify and extract an image and its Xcode disks
                                  (--stream: no archive kept on disk, about half the space)
First install
  init                            create the folder and a host.env to fill in
  install <image> <pool> <name>...  pull, create, register (token on stdin) and start the runners
Upgrade an existing host
  capture <vm> <source image>     once: read an existing runner VM into the folder (then review it)
  upgrade <image> [<name>...]     stop, rebuild from the image + folder, start (old VMs kept)
  rollback <name>...              back to the previous VM and run.sh
Single steps
  create <image> <name>...        build runner VMs from the image + folder
  register <name> <pool>          register a created VM (token on stdin or AC_RUNNER_TOKEN_FILE)
  start|stop [<name>...]          run or stop runners as launchd services (needs sudo)
  status [<name>...]              runners, rollback VMs, services, images
  doctor                          quick host check

Folder: $CFG (host.env, certs/, trust-urls.txt, hosts, files/, tools.txt,
        android-sdk.txt, scripts/, runners/<name>/). Logs in its logs/.
Environment: AC_RUNNER_CONFIG, AC_RUNNER_IMAGE_BASE_URL and AC_RUNNER_CDN_BASE_URL (artifact
        proxy), AC_RUNNER_DOWNLOAD_DIR, AC_RUNNER_TOKEN_FILE, AC_GUEST_PASSWORD.
EOF
}

main() {
  local cmd=${1:-help}
  shift || true
  case "$cmd" in
    images) cmd_images ;;
    pull) [ $# -ge 1 ] || die "usage: pull <image> [--stream]"; lock; start_log pull; cmd_pull "$@" ;;
    init) cmd_init ;;
    install) cmd_install "$@" ;;
    capture) need jq "built into macOS 15+"; cmd_capture "$@" ;;
    create) cmd_create "$@" ;;
    register) cmd_register "$@" ;;
    upgrade) cmd_upgrade "$@" ;;
    rollback) cmd_rollback "$@" ;;
    start) cmd_start "$@" ;;
    stop) cmd_stop "$@" ;;
    status) cmd_status "$@" ;;
    doctor) cmd_doctor ;;
    version|--version|-v) echo "$VERSION" ;;
    help|--help|-h) usage ;;
    *) usage >&2; exit 1 ;;
  esac
}

# Sourced by the tests: functions only.
[ "${RUNNER_VM_SOURCED:-0}" = 1 ] || main "$@"
