#!/usr/bin/env bash
# ==============================================================================
# Appcircle self-hosted macOS runner - launchd service manager
#
# Installs run.sh as a system LaunchDaemon so that runners survive an SSH
# logout and come back automatically after a host reboot.
#
# Why a LaunchDaemon and not `screen`:
#   `screen -d -m run.sh vm01` detaches the process from the terminal but NOT
#   from the SSH login session. When that session is torn down the security
#   context goes with it and tart fails to read the Virtualization.framework
#   HostKey ("VZErrorDomain Code=-9 ... security error"). launchd owns the
#   process instead, so it belongs to no login session at all.
#
# The daemon runs in launchd's system domain but under the runner account, so
# tart sees the same ~/.tart and keychain it does interactively.
#
# Usage, from inside a runner directory (e.g. $HOME/runner1):
#   sudo ./runner-service.sh install vm01
#   sudo ./runner-service.sh status
#   sudo ./runner-service.sh stop            # waits for the VM to power off
#   sudo ./runner-service.sh stop --now      # immediate: kills current build
#   sudo ./runner-service.sh start
#   sudo ./runner-service.sh restart
#   sudo ./runner-service.sh uninstall
#        ./runner-service.sh logs
# ==============================================================================

set -euo pipefail

VERSION="1.0.0"

cd "$(dirname "$0")"
RUNNER_DIR="$(pwd -P)"
RUNNER_NAME="$(basename "$RUNNER_DIR")"
LABEL="io.appcircle.${RUNNER_NAME}"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"

if [ "$(uname -m)" = "arm64" ]; then
  BREW_PREFIX="/opt/homebrew"
else
  BREW_PREFIX="/usr/local"
fi

info() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "This command must be run with sudo."
}

# The account that owns the runner. The daemon runs as this user (not root) so
# that tart sees the same ~/.tart and the same keychain it does interactively.
resolve_runner_user() {
  local u="${SUDO_USER:-$(id -un)}"
  if [ "$u" = "root" ]; then
    u="$(stat -f%Su "${RUNNER_DIR}/run.sh" 2>/dev/null || true)"
  fi
  [ -n "$u" ] && [ "$u" != "root" ] \
    || die "Could not determine the runner user. Run this with sudo from the runner account."
  id -u "$u" >/dev/null 2>&1 || die "User '$u' does not exist."
  printf '%s' "$u"
}

service_loaded() {
  launchctl print "system/${LABEL}" >/dev/null 2>&1
}

# `launchctl unload -w` writes a persistent "disabled" override, so the job
# stays down across reboots until something clears it. That is right for
# uninstall-like intent and wrong for a plain stop, which must not silently
# turn into "never start again".
service_disabled() {
  launchctl print-disabled system 2>/dev/null | grep -q "\"${LABEL}\" => disabled"
}

# Stop without touching the persistent enable/disable state.
service_unload() {
  launchctl bootout "system/${LABEL}" 2>/dev/null \
    || launchctl unload "$PLIST" 2>/dev/null \
    || true
}

service_pid() {
  launchctl print "system/${LABEL}" 2>/dev/null \
    | awk -F'=' '/^[[:space:]]*pid[[:space:]]*=/ {gsub(/[^0-9]/,"",$2); print $2; exit}'
}

# launchd plist values are XML. Refuse paths that would need escaping rather
# than emitting a malformed plist.
assert_xml_safe() {
  case "$1" in
    *'&'*|*'<'*|*'>'*|*'"'*|*"'"*) die "Path contains a character that is unsafe in a plist: $1" ;;
  esac
}

# ------------------------------------------------------------------ install
cmd_install() {
  local vm="${1:-}"
  [ -n "$vm" ] || die "Usage: sudo $0 install <vm-name>   (e.g. vm01)"
  require_root

  local runner_user
  runner_user="$(resolve_runner_user)"

  # run.sh derives the Xcode image directory and the keychain path from $HOME.
  # launchd does populate HOME from the account named by UserName, but relying
  # on that makes a silent wrong-account failure possible if the job is ever
  # started another way, and run.sh uses `set -u`, so an unset HOME aborts it.
  # Resolve the home directory here and declare it in the plist instead.
  local runner_home
  runner_home="$(dscl . -read "/Users/${runner_user}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  [ -d "$runner_home" ] || die "Could not resolve the home directory of '${runner_user}'."

  [ -f "${RUNNER_DIR}/run.sh" ] || die "run.sh not found in ${RUNNER_DIR}"
  [ -x "${RUNNER_DIR}/run.sh" ] || die "run.sh is not executable. Run: chmod u+x ${RUNNER_DIR}/run.sh"

  assert_xml_safe "$RUNNER_DIR"
  assert_xml_safe "$vm"
  assert_xml_safe "$runner_home"

  # Base image check is advisory: tart state is per-user, so query it as the
  # runner account rather than as root.
  #
  # Resolve tart to an absolute path first. `sudo` runs a binary, so it cannot
  # run the `command` builtin, and it resets PATH, so a bare `sudo -u x tart`
  # would not find a Homebrew install either. Both forms fail whether or not
  # tart is present, which turns an advisory check into a permanent warning.
  local tart_bin=""
  if [ -x "${BREW_PREFIX}/bin/tart" ]; then
    tart_bin="${BREW_PREFIX}/bin/tart"
  else
    tart_bin="$(command -v tart 2>/dev/null || true)"
  fi

  if [ -n "$tart_bin" ]; then
    if ! sudo -u "$runner_user" "$tart_bin" list 2>/dev/null | awk '{print $2}' | grep -qx "$vm"; then
      warn "Base image '${vm}' was not found in 'tart list' for user '${runner_user}'."
      warn "Install will continue; the service will wait for it at startup."
    fi
  else
    warn "tart was not found at ${BREW_PREFIX}/bin/tart or on PATH. Install it before starting the service."
  fi

  if [ -f "$PLIST" ]; then
    info "Existing service found, replacing it."
    cmd_uninstall
  fi

  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>

    <key>RunAtLoad</key>
    <true/>

    <!-- Restart on crash, but honour a clean exit. run.sh exits 0 after a
         graceful stop (.stop file); a plain <true/> here would immediately
         restart it and make graceful stops impossible. Do not add
         StartInterval for the same reason: it would also restart a job that
         exited cleanly. -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <!-- launchd does not read .zshrc/.zprofile, so Homebrew's bin directory is
         not on PATH unless it is declared here. Without this, tart is simply
         not found and the service fails at boot. -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOMEBREW_PREFIX</key>
        <string>${BREW_PREFIX}</string>
        <key>HOMEBREW_REPOSITORY</key>
        <string>${BREW_PREFIX}</string>
        <key>HOMEBREW_CELLAR</key>
        <string>${BREW_PREFIX}/Cellar</string>
        <key>HOME</key>
        <string>${runner_home}</string>
    </dict>

    <key>UserName</key>
    <string>${runner_user}</string>

    <key>GroupName</key>
    <string>staff</string>

    <key>WorkingDirectory</key>
    <string>${RUNNER_DIR}</string>

    <!-- Keeps macOS from throttling a long-running build VM. -->
    <key>ProcessType</key>
    <string>Interactive</string>

    <key>StandardOutPath</key>
    <string>${RUNNER_DIR}/service-stdout.log</string>

    <key>StandardErrorPath</key>
    <string>${RUNNER_DIR}/service-stderr.log</string>

    <key>ProgramArguments</key>
    <array>
        <string>${RUNNER_DIR}/run.sh</string>
        <string>${vm}</string>
    </array>
</dict>
</plist>
EOF

  mv "$tmp" "$PLIST"
  chown root:wheel "$PLIST"
  chmod 644 "$PLIST"

  local f
  # run.sh appends to stdout.log and stderr.log rather than truncating, so that
  # a crash loop does not erase the diagnostics from the failure that caused it.
  # Install is therefore the point where the logs are reset, which also bounds
  # their growth.
  local f
  for f in service-stdout.log service-stderr.log stdout.log stderr.log; do
    : > "${RUNNER_DIR}/${f}"
    chown "${runner_user}:staff" "${RUNNER_DIR}/${f}"
  done

  # A .stop left over from a previous manual stop would halt the loop straight
  # away. run.sh clears it at startup too; do it here so `install` is explicit.
  rm -f "${RUNNER_DIR}/.stop" "${RUNNER_DIR}/.stopped"

  info "Installed ${PLIST}"
  info "  runner dir : ${RUNNER_DIR}"
  info "  user       : ${runner_user}"
  info "  vm         : ${vm}"

  launchctl load -w "$PLIST"

  local n=0
  until service_loaded; do
    sleep 1
    n=$((n + 1))
    [ "$n" -ge 15 ] && die "Service did not load within 15s. Check ${RUNNER_DIR}/service-stderr.log"
  done

  info "Service ${LABEL} loaded and started."
  info "Logs: ${RUNNER_DIR}/service-stderr.log (service), ${RUNNER_DIR}/stderr.log (VM loop)"
}

# ---------------------------------------------------------------- uninstall
cmd_uninstall() {
  require_root
  if [ -f "$PLIST" ]; then
    # No -w: the plist is removed anyway, so there is nothing to keep disabled,
    # and a stale override would linger under this label.
    service_unload
    cleanup_clones
    rm -f "$PLIST"
    info "Removed ${PLIST}"
  else
    info "No service installed at ${PLIST}"
  fi
}

# -------------------------------------------------------------------- start
cmd_start() {
  require_root
  [ -f "$PLIST" ] || die "Service is not installed. Run: sudo $0 install <vm-name>"
  if service_loaded; then
    info "Already loaded, kickstarting."
    launchctl kickstart "system/${LABEL}"
  else
    launchctl load -w "$PLIST"
  fi
  info "Started ${LABEL}."
}

# The VM name the service was installed with, read back from the plist.
plist_vm() {
  /usr/libexec/PlistBuddy -c "Print :ProgramArguments:1" "$PLIST" 2>/dev/null
}

# Killing run.sh skips its deleteVM, so the ephemeral clone survives. run.sh
# clears it on the next start, but on a disk-constrained host it should not sit
# there in between.
cleanup_clones() {
  local vm user c found=0
  vm="$(plist_vm)"
  [ -n "$vm" ] || return 0
  user="$(resolve_runner_user)"
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    found=1
    sudo -u "$user" tart stop "$c" >/dev/null 2>&1 || true
    if sudo -u "$user" tart delete "$c" >/dev/null 2>&1; then
      info "Deleted leftover clone: $c"
    else
      warn "Could not delete leftover clone: $c"
    fi
  done < <(sudo -u "$user" tart list 2>/dev/null | awk -v p="^${vm}-" '$2 ~ p {print $2}')
  [ "$found" = 0 ] && info "No leftover clones for '${vm}'."
  return 0
}

stop_service() {
  if [ "${1:-0}" = 1 ]; then
    launchctl unload -w "$PLIST" 2>/dev/null || true
    cleanup_clones
    info "Stopped ${LABEL} and disabled it. It will NOT start after a reboot."
    info "Bring it back with: sudo $0 start"
  else
    service_unload
    cleanup_clones
    info "Stopped ${LABEL}. It will start again on the next host reboot."
    info "Use '--disable' if you want it to stay down across reboots."
  fi
}

# --------------------------------------------------------------------- stop
cmd_stop() {
  require_root
  [ -f "$PLIST" ] || die "Service is not installed."

  local now=0 timeout=1800 disable=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --now)     now=1 ;;
      --disable) disable=1 ;;
      --timeout) shift; timeout="${1:-1800}" ;;
      *)         die "Unknown option for stop: $1" ;;
    esac
    shift || true
  done

  if [ "$now" = 1 ]; then
    warn "Stopping immediately. A build running right now will be killed."
    stop_service "$disable"
    return 0
  fi

  if ! service_loaded; then
    info "Service is not running."
    return 0
  fi

  local runner_user vm
  runner_user="$(resolve_runner_user)"
  vm="$(plist_vm)"
  sudo -u "$runner_user" touch "${RUNNER_DIR}/.stop"

  # IMPORTANT: run.sh only tests .stop at the top of its loop, and the loop
  # body blocks in `tart run` until the VM powers off. A VM powers off after it
  # finishes a build - an idle runner with no work queued will not exit on its
  # own, so this wait can run to the full timeout. Say so instead of implying
  # it is only ever about a build in progress.
  if pgrep -f "tart run ${vm}-" >/dev/null 2>&1; then
    info "A VM is running. Waiting for it to power off (timeout $((timeout / 60)) min)."
    info "It powers off after it completes a build. An idle runner will NOT exit on its own -"
    info "use 'sudo $0 stop --now' if the runner has no work to finish."
  else
    info "No VM running. run.sh will exit on its next loop check."
  fi

  local waited=0
  while [ -n "$(service_pid)" ]; do
    sleep 5
    waited=$((waited + 5))
    if [ "$waited" -ge "$timeout" ]; then
      err "Still running after $((timeout / 60)) minutes. Use 'sudo $0 stop --now' to force."
      return 2
    fi
  done

  stop_service "$disable"
}

# ------------------------------------------------------------------ restart
cmd_restart() {
  require_root
  cmd_stop "$@"
  cmd_start
}

# ------------------------------------------------------------------- status
cmd_status() {
  if [ ! -f "$PLIST" ]; then
    info "Service    : not installed (${PLIST} missing)"
  else
    info "Service    : installed at ${PLIST}"
  fi

  if service_loaded; then
    local pid
    pid="$(service_pid)"
    info "State      : loaded${pid:+, pid ${pid}}"
    service_disabled && warn "Disabled   : marked disabled - it will NOT come back after a reboot (sudo $0 start)"
    launchctl print "system/${LABEL}" 2>/dev/null \
      | awk -F'=' '/^[[:space:]]*(state|username|path|last exit code)[[:space:]]*=/ {sub(/^[[:space:]]+/,""); print "             " $0}'
  else
    if service_disabled; then
      warn "State      : not loaded AND marked disabled - it will NOT start at boot (sudo $0 start)"
    else
      info "State      : not loaded, but enabled - it will start at the next boot"
    fi
  fi

  info "Runner dir : ${RUNNER_DIR}"
  [ -e "${RUNNER_DIR}/.stop" ] && warn ".stop is present - the loop will exit after the current build."

  if command -v tart >/dev/null 2>&1; then
    info "VMs:"
    tart list 2>/dev/null | sed 's/^/             /' || true
  fi
}

# --------------------------------------------------------------------- logs
cmd_logs() {
  info "Tailing ${RUNNER_DIR}/service-stderr.log and ${RUNNER_DIR}/stderr.log (Ctrl-C to stop)"
  tail -f "${RUNNER_DIR}/service-stderr.log" "${RUNNER_DIR}/stderr.log"
}

usage() {
  cat <<EOF
Appcircle runner launchd service manager v${VERSION}

  sudo $0 install <vm-name>   Install and start the service
  sudo $0 uninstall           Stop and remove the service
  sudo $0 start               Start (or kickstart) the service
  sudo $0 stop [--now] [--disable] [--timeout N]
                              Wait for the running VM to power off, then stop.
                              A VM powers off after it finishes a build, so an
                              IDLE runner will not exit on its own - use --now.
                              --now stops at once, killing any running build.
                              Both delete the leftover ephemeral clone.
                              The service still starts again after a reboot;
                              add --disable to keep it down across reboots.
  sudo $0 restart [--now]     Stop then start
       $0 status              Show service and VM state
       $0 logs                Tail the service and VM loop logs

Label : ${LABEL}   (derived from the directory name '${RUNNER_NAME}')
Plist : ${PLIST}
EOF
}

case "${1:-}" in
  install)   shift; cmd_install "${1:-}" ;;
  uninstall) cmd_uninstall ;;
  start)     cmd_start ;;
  stop)      shift; cmd_stop "$@" ;;
  restart)   shift; cmd_restart "$@" ;;
  status)    cmd_status ;;
  logs)      cmd_logs ;;
  -h|--help|help|"") usage ;;
  *) err "Unknown command: $1"; usage; exit 1 ;;
esac
