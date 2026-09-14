#!/usr/bin/env bash
# ==============================================================================
# Appcircle self-hosted macOS runner host - readiness check
#
# READ ONLY. Changes nothing on the host. Safe to run against a live runner.
#
# Detects how the runners are supervised (system LaunchDaemon, gui-domain
# LaunchAgent, bare `screen`, or nothing) and grades the session-related checks
# accordingly: a LaunchDaemon starts at boot with no login session, a
# LaunchAgent cannot exist without one.
#
# Usage:
#   ssh user@host 'bash -s' < check-runner-host.sh
#   APPCIRCLE_URL=https://appcircle.customer.com ./check-runner-host.sh
#
# Environment:
#   APPCIRCLE_URL   Appcircle server to reach (default https://my.appcircle.io).
#                   Set this to your own domain on a self-hosted installation.
#   RUNNER_USER     Account that owns the runners (default: current user).
#   SKIP_NET=1      Skip all network reachability checks.
#
# Exit codes: 0 = ready (warnings allowed), 1 = not ready (at least one FAIL).
# ==============================================================================

version="1.0.0"

APPCIRCLE_URL="${APPCIRCLE_URL:-https://my.appcircle.io}"
RUNNER_USER="${RUNNER_USER:-$(id -un)}"
RUNNER_UID="$(id -u "$RUNNER_USER" 2>/dev/null || id -u)"
# Strip the attribute name rather than taking the second field: dscl prints
# "NFSHomeDirectory: /Users/foo", so `awk '{print $2}'` would cut a home
# directory containing a space down to its first word.
RUNNER_HOME="$(dscl . -read "/Users/$RUNNER_USER" NFSHomeDirectory 2>/dev/null \
  | sed -n 's/^NFSHomeDirectory: //p')"
[ -d "$RUNNER_HOME" ] || RUNNER_HOME="$HOME"
SKIP_NET="${SKIP_NET:-0}"

PASS=0; WARN=0; FAIL=0
FAIL_LIST=""; WARN_LIST=""
TMP="$(mktemp -d /tmp/ac-hostcheck.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

if [ -t 1 ]; then
  c_g=$'\033[32m'; c_y=$'\033[33m'; c_r=$'\033[31m'; c_b=$'\033[1m'; c_d=$'\033[2m'; c_0=$'\033[0m'
else
  c_g=""; c_y=""; c_r=""; c_b=""; c_d=""; c_0=""
fi

ok()   { printf "  ${c_g}PASS${c_0}  %-32s %s\n" "$1" "$2"; PASS=$((PASS+1)); }
warn() { printf "  ${c_y}WARN${c_0}  %-32s %s\n" "$1" "$2"; WARN=$((WARN+1)); WARN_LIST="${WARN_LIST}  - $1: $2"$'\n'; }
bad()  { printf "  ${c_r}FAIL${c_0}  %-32s %s\n" "$1" "$2"; FAIL=$((FAIL+1)); FAIL_LIST="${FAIL_LIST}  - $1: $2"$'\n'; }
skip() { printf "  ${c_d}SKIP${c_0}  %-32s %s\n" "$1" "$2"; }
info() { printf "  ${c_d}info${c_0}  %-32s %s\n" "$1" "$2"; }
detail() { printf "        ${c_d}%s${c_0}\n" "$1"; }
section() { printf "\n${c_b}== %s${c_0}\n" "$1"; }

HAVE_SUDO=0
sudo -n true 2>/dev/null && HAVE_SUDO=1

# Run a command inside the runner user's Aqua (GUI) login session.
# This is the context tart actually needs; an SSH shell is NOT that context.
asuser() {
  [ "$HAVE_SUDO" = 1 ] || return 127
  sudo -n launchctl asuser "$RUNNER_UID" sudo -n -u "$RUNNER_USER" "$@" 2>&1
}

# Whether tart can reach the Virtualization.framework HostKey without a
# desktop session depends on the macOS release.
#
#   macOS 13.4  - a system LaunchDaemon runs tart with no session at all.
#   macOS 26.6  - the same daemon fails with VZErrorDomain -9 ("Failed to get
#                 current host key") unless a desktop session exists. Adding
#                 SessionCreate to the job does not help.
#
# 14 and 15 are untested. Treat anything above the last known-good release as
# requiring a session, so an unverified host is flagged rather than quietly
# passed.
OS_MAJOR=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)
case "$OS_MAJOR" in
  ''|*[!0-9]*) HOSTKEY_NEEDS_SESSION=1 ;;
  *) [ "$OS_MAJOR" -le 13 ] && HOSTKEY_NEEDS_SESSION=0 || HOSTKEY_NEEDS_SESSION=1 ;;
esac

# That requirement is satisfiable without a desktop login. What tart actually
# needs is an unlocked file-based login keychain, not an Aqua session, and
# run.sh (1.9.0+) unlocks it itself at startup when a password file is present.
# Measured on macOS 26.6.2: a daemon configured this way came back after a
# reboot with neither an SSH nor a desktop login, picked up a queued build and
# finished it. So auto-login is a fallback here, not a prerequisite.
KC_UNLOCK_FILE="${KEYCHAIN_PW_FILE:-$RUNNER_HOME/.appcircle/runner-keychain.pw}"
KC_UNLOCK=0
[ -f "$KC_UNLOCK_FILE" ] && KC_UNLOCK=1

# How the runners are (or are not) supervised. This decides how strict the
# session checks in section 3 are: a gui-domain LaunchAgent cannot exist until
# someone is logged in, and on a release that needs one, neither can tart.
AC_DAEMONS="$(ls /Library/LaunchDaemons/io.appcircle.* 2>/dev/null || true)"
AC_AGENTS="$(ls "$RUNNER_HOME"/Library/LaunchAgents/io.appcircle.* 2>/dev/null || true)"
if [ -n "$AC_DAEMONS" ]; then
  MODE="daemon"
elif [ -n "$AC_AGENTS" ]; then
  MODE="agent"
elif pgrep -f 'run\.sh' >/dev/null 2>&1; then
  MODE="screen"
else
  MODE="none"
fi

printf "${c_b}Appcircle runner host readiness check${c_0}\n"
printf "  host=%s  user=%s(uid=%s)  date=%s\n" \
  "$(hostname)" "$RUNNER_USER" "$RUNNER_UID" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
printf "  supervision=%s\n" "$MODE"
printf "  appcircle_url=%s  sudo=%s\n" "$APPCIRCLE_URL" "$([ "$HAVE_SUDO" = 1 ] && echo available || echo unavailable)"
[ "$HAVE_SUDO" = 0 ] && printf "  ${c_y}Note: passwordless sudo unavailable. Session-context and policy checks will be skipped.${c_0}\n"
[ -n "$SSH_CONNECTION" ] && printf "  ${c_d}Running over SSH. Checks report host state, not this SSH session.${c_0}\n"

# ==============================================================================
section "1. System"
# ==============================================================================
info "macOS" "$(sw_vers -productVersion) build $(sw_vers -buildVersion) ($(uname -m))"
info "Model" "$(sysctl -n hw.model 2>/dev/null)"
MEM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
info "Memory / CPU" "${MEM_GB} GB / $(sysctl -n hw.ncpu) cores"
info "Uptime" "$(uptime | sed 's/.*up \([^,]*\),.*/\1/' | sed 's/^ *//')"

DF_AVAIL_GB=$(df -g / | awk 'NR==2{print $4}')
DF_PCT=$(df / | awk 'NR==2{gsub("%","",$5); print $5}')
info "Disk free" "${DF_AVAIL_GB} GB available (${DF_PCT}% used)"
if [ "$DF_AVAIL_GB" -lt 100 ]; then
  bad "Disk capacity" "${DF_AVAIL_GB} GB free - VM clones and Xcode images need 100 GB+"
elif [ "$DF_PCT" -ge 85 ]; then
  warn "Disk capacity" "${DF_PCT}% used - low headroom for VM clones"
else
  ok "Disk capacity" "${DF_AVAIL_GB} GB free"
fi

if [ "$MEM_GB" -lt 16 ]; then
  warn "Memory sizing" "${MEM_GB} GB - supports only 1 VM (16 GB+ needed for 2)"
else
  ok "Memory sizing" "${MEM_GB} GB - supports 2 VMs at 8 GB each"
fi

# ==============================================================================
section "2. Device management and policy (MDM)"
# ==============================================================================
# Enterprise hosts are often MDM-managed. A configuration profile can silently
# override every local setting this script checks below.
ENROLL=$(profiles status -type enrollment 2>&1)
if echo "$ENROLL" | grep -qi "MDM enrollment: Yes"; then
  warn "MDM enrollment" "host is MDM-managed - profiles may override local settings"
  echo "$ENROLL" | sed 's/^/        /'
elif echo "$ENROLL" | grep -qi "MDM enrollment: No"; then
  ok "MDM enrollment" "not enrolled - local settings are authoritative"
else
  skip "MDM enrollment" "could not determine"
fi

if [ "$HAVE_SUDO" = 1 ]; then
  sudo -n profiles -P -o stdout 2>/dev/null > "$TMP/profiles.txt" || \
    sudo -n profiles list 2>/dev/null > "$TMP/profiles.txt"
  if [ -s "$TMP/profiles.txt" ]; then
    PROF_N=$(grep -cE "attribute: name|<key>PayloadDisplayName</key>" "$TMP/profiles.txt" 2>/dev/null)
    info "Configuration profiles" "${PROF_N:-0} payload(s) detected"
    # Payloads that directly break the runner solution
    for pat in loginwindow:"login window policy (may block auto-login)" \
               FileVault:"FileVault enforcement" \
               SoftwareUpdate:"software update policy (may force reboots)" \
               screensaver:"screen saver / lock policy" \
               passwordpolicy:"password rotation policy (breaks auto-login over time)" \
               MCXLoginItems:"managed login items"; do
      key="${pat%%:*}"; desc="${pat#*:}"
      grep -qi "$key" "$TMP/profiles.txt" && warn "Profile payload: $key" "$desc"
    done
  else
    skip "Configuration profiles" "could not read profile list"
  fi
else
  skip "Configuration profiles" "needs sudo - run: sudo profiles -P"
fi

# Password rotation is the single most common cause of this solution decaying
# months after a successful install: kcpassword and the keychain both go stale.
if [ "$HAVE_SUDO" = 1 ]; then
  PWPOL=$(sudo -n pwpolicy -u "$RUNNER_USER" -getaccountpolicies 2>/dev/null | grep -i -o 'policyAttributeExpiresEveryNDays[^<]*<integer>[0-9]*' | grep -o '[0-9]*$')
  if [ -n "$PWPOL" ] && [ "$PWPOL" -gt 0 ] 2>/dev/null; then
    bad "Password expiry policy" "expires every ${PWPOL} days - will break auto-login and keychain unlock"
  else
    ok "Password expiry policy" "no expiry policy detected for $RUNNER_USER"
  fi
else
  skip "Password expiry policy" "needs sudo - run: sudo pwpolicy -u $RUNNER_USER -getaccountpolicies"
fi

# Network/directory accounts do not support auto-login reliably.
NODE=$(dscl . -read "/Users/$RUNNER_USER" OriginalNodeName 2>/dev/null | tail -n1 | sed 's/^ *//')
if [ -n "$NODE" ] && [ "$NODE" != "OriginalNodeName" ]; then
  bad "Account type" "$RUNNER_USER is a directory/mobile account ($NODE) - use a local account"
else
  ok "Account type" "$RUNNER_USER is a local account"
fi

# ==============================================================================
section "3. GUI session and keychain"
# ==============================================================================
# An SSH shell is a separate security session from the Aqua (desktop) one,
# which is why `screen -d -m run.sh` dies on logout: tart can no longer reach
# the Virtualization.framework HostKey.
#
# Whether a LaunchDaemon also needs one depends on the release, decided in
# HOSTKEY_NEEDS_SESSION above. Under `agent` mode a missing session is always
# fatal, because launchd cannot start a gui-domain job without one.
CONSOLE_USER=$(stat -f%Su /dev/console 2>/dev/null)
case "$CONSOLE_USER" in
  root|_mbsetupuser|"")
    case "$MODE" in
      agent) bad "GUI (Aqua) session" "console user is '${CONSOLE_USER:-none}' - a LaunchAgent cannot run without it" ;;
      daemon)
        if [ "$HOSTKEY_NEEDS_SESSION" = 1 ] && [ "$KC_UNLOCK" = 0 ]; then
          bad "GUI (Aqua) session" "console user is '${CONSOLE_USER:-none}' - on macOS ${OS_MAJOR} tart cannot reach the HostKey without one, and no keychain unlock credential is configured (VZErrorDomain -9)"
        elif [ "$HOSTKEY_NEEDS_SESSION" = 1 ]; then
          info "GUI (Aqua) session" "console user is '${CONSOLE_USER:-none}' - not needed, run.sh unlocks the login keychain itself"
        else
          info "GUI (Aqua) session" "console user is '${CONSOLE_USER:-none}' - none needed by a LaunchDaemon on macOS ${OS_MAJOR}"
        fi ;;
      *) warn "GUI (Aqua) session" "console user is '${CONSOLE_USER:-none}' - no desktop session" ;;
    esac ;;
  "$RUNNER_USER")
    ok "GUI (Aqua) session" "console user: $CONSOLE_USER" ;;
  *)
    warn "GUI (Aqua) session" "console user is '$CONSOLE_USER', expected '$RUNNER_USER'" ;;
esac

# Report boot and console-login times as facts rather than guessing at them.
# /dev/console's mtime is NOT the login time - it is the last write to the
# device - so it cannot be used to date the session.
info "Boot" "$(who -b 2>/dev/null | sed 's/^[[:space:]]*//' || true)"
CONSOLE_LINE=$(who 2>/dev/null | awk '$2=="console"{sub(/^[ \t]+/,""); print; exit}')
if [ -n "$CONSOLE_LINE" ]; then
  info "Console session" "$CONSOLE_LINE"
  detail "A console login much later than boot means a manual login, not auto-login."
else
  info "Console session" "none listed by 'who'"
fi

# sysadminctl's wording differs across macOS releases. Observed forms:
#   "Automatic login user: appcircle"     enabled  (macOS 13+)
#   "Automatic login is OFF."             disabled
#   "autologin is set for user <name>"    enabled  (older builds)
# Every line is prefixed with a timestamp, so match on the phrase, not the
# line start. Fall back to the preference key when sudo is unavailable.
# Tri-state on purpose. sysadminctl is authoritative whenever it answers; the
# autoLoginUser preference is only a fallback for when it cannot be consulted.
# Switching auto-login off does not reliably clear that preference, so a stale
# key is common and must never be allowed to override an explicit "OFF".
AL=""
[ "$HAVE_SUDO" = 1 ] && AL=$(sudo -n sysadminctl -autologin status 2>&1)
AL_STATE="unknown"
AL_USER=""
case "$AL" in
  *"Automatic login is OFF"*|*"autologin is not set"*)
    AL_STATE="off" ;;
  *"Automatic login user:"*)
    AL_STATE="on"
    AL_USER=$(printf '%s' "$AL" | sed -n 's/.*Automatic login user:[[:space:]]*//p' | tail -n1 | tr -d '[:space:]') ;;
  *"autologin is set for user"*)
    AL_STATE="on"
    AL_USER=$(printf '%s' "$AL" | sed -n 's/.*autologin is set for user[[:space:]]*//p' | tail -n1 | tr -d '[:space:]') ;;
esac

AL_PREF=$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)
KC_FILE=0
[ -f /etc/kcpassword ] && KC_FILE=1

# Fall back to the preference ONLY when sysadminctl could not be consulted, and
# only together with /etc/kcpassword: without that file macOS does not log in,
# whatever the preference says.
if [ "$AL_STATE" = "unknown" ]; then
  if [ -n "$AL_PREF" ] && [ "$KC_FILE" = 1 ]; then
    AL_STATE="on"
    AL_USER="$AL_PREF"
  elif [ -z "$AL_PREF" ]; then
    AL_STATE="off"
  fi
fi

# A leftover preference with auto-login actually off is untidy but harmless.
# Surface it so nobody reads it as evidence that auto-login is configured.
[ "$AL_STATE" = "off" ] && [ -n "$AL_PREF" ] && \
  info "Auto-login preference" "stale autoLoginUser='$AL_PREF' left in com.apple.loginwindow while auto-login is off"

if [ "$AL_STATE" = "on" ]; then
  ok "Auto-login" "enabled for '${AL_USER:-unknown}'"
  [ -n "$AL_USER" ] && [ "$AL_USER" != "$RUNNER_USER" ] && \
    warn "Auto-login user" "set to '$AL_USER' but runners belong to '$RUNNER_USER'"
  [ "$KC_FILE" = 0 ] && \
    warn "Auto-login credential" "/etc/kcpassword missing while auto-login is set - macOS will not actually log in"
elif [ "$AL_STATE" = "unknown" ]; then
  warn "Auto-login" "could not be determined - run: sudo sysadminctl -autologin status"
elif [ "$KC_FILE" = 1 ]; then
  # Contradictory state: trust neither side, say so instead of picking one.
  warn "Auto-login" "reported off, but /etc/kcpassword exists - verify with: sudo sysadminctl -autologin status"
elif [ "$MODE" = "agent" ]; then
  bad "Auto-login" "disabled - a LaunchAgent has no session to load into after reboot"
elif [ "$MODE" = "daemon" ] && [ "$HOSTKEY_NEEDS_SESSION" = 1 ] && [ "$KC_UNLOCK" = 0 ]; then
  bad "Auto-login" "disabled - on macOS ${OS_MAJOR} the daemon needs a desktop session unless run.sh unlocks the keychain, so nothing runs after a reboot. Fix: configure $KC_UNLOCK_FILE, or enable auto-login"
elif [ "$MODE" = "daemon" ] && [ "$HOSTKEY_NEEDS_SESSION" = 1 ]; then
  info "Auto-login" "disabled - not required, run.sh unlocks the login keychain from the daemon itself"
elif [ "$MODE" = "daemon" ]; then
  info "Auto-login" "disabled - not required on macOS ${OS_MAJOR}, the daemon starts at boot without a session"
elif [ "$HOSTKEY_NEEDS_SESSION" = 1 ]; then
  warn "Auto-login" "disabled - required on macOS ${OS_MAJOR} for a runner to survive a reboot"
else
  info "Auto-login" "disabled - not required once runners are installed as a LaunchDaemon"
fi

[ "$KC_FILE" = 1 ] && \
  info "Auto-login credential" "/etc/kcpassword present ($(stat -f '%Sp %Su:%Sg' /etc/kcpassword))"

FV=$(fdesetup status 2>/dev/null)
case "$FV" in
  *"FileVault is Off"*) ok "FileVault" "off - the host can boot unattended" ;;
  *"FileVault is On"*)
    bad "FileVault" "ON - pre-boot authentication is required, so the host cannot reboot unattended" ;;
  *) skip "FileVault" "could not determine" ;;
esac

# Keychain state differs by session. Check BOTH contexts: the difference is the
# whole point. SSH failing while Aqua succeeds is expected macOS behaviour and
# is exactly why run.sh must not be launched from an SSH shell.
KC_PATH="$RUNNER_HOME/Library/Keychains/login.keychain-db"
KC_SSH=$(security show-keychain-info "$KC_PATH" 2>&1)
KC_GUI=$(asuser security show-keychain-info "$KC_PATH")
KC_RC=$?

describe_kc() {
  case "$1" in
    *no-timeout*)                  echo "unlocked, no auto-lock timeout" ;;
    *lock-on-sleep*)               echo "unlocked but locks on sleep" ;;
    *timeout*)                     echo "unlocked with auto-lock timeout: $(echo "$1" | tr -d '\n')" ;;
    *"User interaction is not allowed"*) echo "not reachable from this session" ;;
    *locked*)                      echo "LOCKED" ;;
    *)                             echo "$(echo "$1" | tr -d '\n')" ;;
  esac
}

GUI_OK=0
launchctl print "gui/$RUNNER_UID" >/dev/null 2>&1 && GUI_OK=1

# The session-less path depends on this one being unlocked with no auto-lock,
# so grade it instead of only reporting it. The unlock survives the session that
# performed it, which is why a daemon-side unlock is visible from here at all.
if [ "$KC_UNLOCK" = 1 ] || { [ "$MODE" = "daemon" ] && [ "$HOSTKEY_NEEDS_SESSION" = 1 ]; }; then
  case "$KC_SSH" in
    *no-timeout*)
      ok "Keychain (SSH context)" "unlocked, no auto-lock timeout - correct for a LaunchDaemon" ;;
    *lock-on-sleep*|*timeout*)
      bad "Keychain (SSH context)" "auto-lock is set ($(echo "$KC_SSH" | tr -d '\n')) - the first build passes and the next one fails once it locks. Fix: security set-keychain-settings $KC_PATH" ;;
    *)
      warn "Keychain (SSH context)" "$(describe_kc "$KC_SSH") - expected unlocked with no timeout. Has run.sh started yet?" ;;
  esac
else
  info "Keychain (SSH context)" "$(describe_kc "$KC_SSH")"
fi

# The credential run.sh uses to perform that unlock at boot.
if [ "$KC_UNLOCK" = 1 ]; then
  KC_STAT=$(stat -f '%Sp %Su:%Sg' "$KC_UNLOCK_FILE" 2>/dev/null)
  case "$KC_STAT" in
    "-rw------- $RUNNER_USER:"*)
      ok "Keychain unlock credential" "$KC_UNLOCK_FILE ($KC_STAT) - auto-login is not required on this host" ;;
    *)
      warn "Keychain unlock credential" "$KC_UNLOCK_FILE is '$KC_STAT' - should be mode 600 owned by $RUNNER_USER" ;;
  esac
elif [ "$MODE" = "daemon" ] && [ "$HOSTKEY_NEEDS_SESSION" = 1 ]; then
  warn "Keychain unlock credential" "none at $KC_UNLOCK_FILE - without it the daemon falls back to needing auto-login on macOS ${OS_MAJOR}"
fi

if [ "$KC_RC" = 127 ]; then
  skip "Keychain (Aqua context)" "needs sudo - run: sudo launchctl asuser $RUNNER_UID sudo -u $RUNNER_USER security show-keychain-info"
elif [ "$GUI_OK" = 0 ]; then
  # Without a GUI session there is no Aqua context to query, so a failure here
  # says nothing about the keychain itself. Do not report it as locked. Under a
  # LaunchDaemon this is expected and harmless - tart does not need it.
  skip "Keychain (Aqua context)" "no GUI session for uid $RUNNER_UID - nothing to query, and not needed by a LaunchDaemon"
else
  case "$KC_GUI" in
    *no-timeout*)
      ok "Keychain (Aqua context)" "unlocked, no auto-lock timeout - correct for tart" ;;
    *lock-on-sleep*|*timeout*)
      bad "Keychain (Aqua context)" "auto-lock is set ($(echo "$KC_GUI" | tr -d '\n')) - tart will fail once it locks" ;;
    *"User interaction is not allowed"*|*locked*)
      bad "Keychain (Aqua context)" "locked even inside the GUI session - keychain password likely differs from the account password" ;;
    *)
      warn "Keychain (Aqua context)" "unexpected: $(echo "$KC_GUI" | tr -d '\n')" ;;
  esac
fi

if [ "$GUI_OK" = 1 ]; then
  ok "launchd gui domain" "gui/$RUNNER_UID reachable"
elif [ "$MODE" = "agent" ]; then
  bad "launchd gui domain" "gui/$RUNNER_UID unreachable - the installed LaunchAgent cannot run"
else
  info "launchd gui domain" "gui/$RUNNER_UID unreachable - not required for a LaunchDaemon"
fi

if [ "$HAVE_SUDO" = 1 ]; then
  ST=$(sudo -n sysadminctl -secureTokenStatus "$RUNNER_USER" 2>&1)
  echo "$ST" | grep -qi "ENABLED" && info "Secure token" "enabled for $RUNNER_USER" \
                                  || info "Secure token" "disabled for $RUNNER_USER"
fi

# ==============================================================================
section "4. Power and availability"
# ==============================================================================
PM=$(pmset -g custom 2>/dev/null)
for k in sleep disksleep displaysleep; do
  V=$(echo "$PM" | awk -v k="$k" '$1==k{print $2; exit}')
  if [ -z "$V" ]; then skip "pmset $k" "not reported"
  elif [ "$V" = "0" ]; then ok "pmset $k" "0 (never)"
  else bad "pmset $k" "$V min - host sleeps when idle and runners go offline"; fi
done

V=$(echo "$PM" | awk '$1=="womp"{print $2; exit}')
[ "$V" = "1" ] && ok "Wake on network access" "enabled" || warn "Wake on network access" "womp=${V:-unset}"
V=$(echo "$PM" | awk '$1=="autorestart"{print $2; exit}')
[ "$V" = "1" ] && ok "Restart after power failure" "enabled" || warn "Restart after power failure" "autorestart=${V:-unset}"

if [ "$HAVE_SUDO" = 1 ]; then
  sudo -n systemsetup -getremotelogin 2>/dev/null | grep -qi "On" \
    && ok "Remote Login (SSH)" "enabled - remote recovery possible" \
    || warn "Remote Login (SSH)" "disabled or unknown"
fi
if launchctl print system/com.apple.screensharing >/dev/null 2>&1; then
  ok "Screen Sharing" "enabled - GUI recovery possible on a headless host"
else
  warn "Screen Sharing" "disabled, or not visible without sudo - verify a GUI recovery path exists"
fi

# ==============================================================================
section "5. Automatic updates (unexpected reboots)"
# ==============================================================================
chk_def() {
  V=$(defaults read "$1" "$2" 2>/dev/null)
  if [ "$V" = "0" ]; then ok "$2" "disabled"; else warn "$2" "${V:-unset} - should be 0"; fi
}
chk_def /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled
chk_def /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload
chk_def /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall
chk_def /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates
chk_def /Library/Preferences/com.apple.commerce AutoUpdate
info "Last boot" "$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*} \(.*\)/\1/p')"

# ==============================================================================
section "6. Security posture"
# ==============================================================================
spctl --status 2>/dev/null | grep -qi "assessments enabled" \
  && info "Gatekeeper" "enabled - unsigned binaries need an explicit exception" \
  || info "Gatekeeper" "disabled"
csrutil status 2>/dev/null | grep -qi "enabled" \
  && info "SIP" "enabled" || warn "SIP" "disabled - unexpected on a managed host"

SS_ASK=$(defaults -currentHost read com.apple.screensaver askForPassword 2>/dev/null)
if [ "$SS_ASK" = "1" ]; then
  ok "Screen lock" "password required - safe to pair with auto-login"
else
  warn "Screen lock" "no password on wake - auto-login leaves the desktop exposed"
fi
# systemsetup -gettimezone needs admin and prints its refusal on stdout with
# exit 0, so it cannot be used unguarded. Read the zoneinfo symlink instead.
TZ_NAME=$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')
info "Time zone" "${TZ_NAME:-$(date '+%Z')}  ($(date '+%Y-%m-%d %H:%M:%S %z'))"
if [ "$HAVE_SUDO" = 1 ]; then
  sudo -n systemsetup -getusingnetworktime 2>/dev/null | grep -qi "On" \
    && ok "Network time" "enabled - clock skew will not break TLS or signing" \
    || bad "Network time" "disabled - clock skew breaks TLS, notarization and signing"
fi

# ==============================================================================
section "7. Certificates and TLS interception"
# ==============================================================================
# Where a TLS-intercepting proxy is in use, its root CA must be trusted on the
# HOST *and* baked into the base VM images - anything installed into an
# ephemeral instance is lost on the next build.
security find-certificate -a -p /Library/Keychains/System.keychain 2>/dev/null > "$TMP/roots.pem"
NROOTS=$(grep -c 'BEGIN CERTIFICATE' "$TMP/roots.pem" 2>/dev/null)
NROOTS=${NROOTS:-0}
if [ "$NROOTS" -gt 0 ]; then
  awk -v d="$TMP" '/BEGIN CERTIFICATE/{n++} {print > (d "/root-" n ".pem")}' "$TMP/roots.pem"
  NCUSTOM=0
  for f in "$TMP"/root-*.pem; do
    [ -f "$f" ] || continue
    SUBJ=$(openssl x509 -in "$f" -noout -subject 2>/dev/null | sed 's/^subject= *//' | cut -c1-70)
    # Every Mac ships these auto-generated local identities in the System
    # keychain. Counting them as corporate CAs makes a clean host look
    # MITM-proxied.
    case "$SUBJ" in
      *com.apple.systemdefault*|*com.apple.kerberos.kdc*|*"O=System Identity"*)
        continue ;;
    esac

    END=$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
    EXPIRED=0
    openssl x509 -in "$f" -noout -checkend 0 >/dev/null 2>&1 || EXPIRED=1

    # Apple's own intermediates also live here and are routinely superseded
    # rather than removed, so an expired one is normal and does not block a
    # runner host. Only a genuinely third-party CA expiring is a real problem.
    case "$SUBJ" in
      *"O=Apple Inc."*|*"Apple Worldwide Developer Relations"*)
        if [ "$EXPIRED" = 1 ]; then
          info "Apple certificate" "$SUBJ expired $END - normally a superseded intermediate, harmless here"
        else
          detail "valid until $END  $SUBJ"
        fi
        continue ;;
    esac

    NCUSTOM=$((NCUSTOM + 1))
    if [ "$EXPIRED" = 1 ]; then
      bad "Certificate expired" "$SUBJ (expired $END)"
    elif ! openssl x509 -in "$f" -noout -checkend 2592000 >/dev/null 2>&1; then
      warn "Certificate expiring" "$SUBJ (expires $END, under 30 days)"
    else
      detail "valid until $END  $SUBJ"
    fi
  done
  if [ "$NCUSTOM" -gt 0 ]; then
    info "Custom certificates" "$NCUSTOM non-Apple certificate(s) in the System keychain"
    detail "A corporate CA must also be baked into the vm01/vm02 base images - ephemeral instances lose it every build."
  else
    ok "Custom certificates" "none beyond Apple's built-in system identities"
  fi
else
  ok "Custom certificates" "none in System keychain - no corporate CA installed"
fi

if [ "$SKIP_NET" != "1" ]; then
  # NOTE: parameter expansion, not sed. BSD sed (macOS) has no \? in BRE, so
  # 's#^https\?://##' silently does nothing there and leaves "https:" behind.
  HOSTPORT="${APPCIRCLE_URL#*://}"
  HOSTPORT="${HOSTPORT%%/*}"
  ISSUER=$(echo | openssl s_client -connect "${HOSTPORT}:443" -servername "$HOSTPORT" 2>/dev/null \
           | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer= *//')
  if [ -z "$ISSUER" ]; then
    warn "TLS to Appcircle" "could not complete a TLS handshake with $HOSTPORT"
  elif echo "$ISSUER" | grep -qiE "let'?s encrypt|digicert|sectigo|globalsign|amazon|google trust|zerossl|isrg"; then
    ok "TLS interception" "not intercepted (issuer: $(echo "$ISSUER" | cut -c1-60))"
  else
    warn "TLS interception" "non-public issuer, proxy likely: $(echo "$ISSUER" | cut -c1-60)"
    detail "The same CA must be trusted inside vm01/vm02 base images, not just on the host."
  fi
fi

# ==============================================================================
section "8. Network and proxy"
# ==============================================================================
PROXY=$(scutil --proxy 2>/dev/null)
if echo "$PROXY" | grep -qE 'HTTPEnable *: *1|HTTPSEnable *: *1'; then
  warn "System proxy" "configured - LaunchAgent does NOT inherit shell env, set it in the plist"
  echo "$PROXY" | grep -E 'HTTPProxy|HTTPSProxy|ProxyAutoConfig|Port' | sed 's/^/        /'
else
  ok "System proxy" "not configured"
fi
for v in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy; do
  eval "val=\${$v}"
  [ -n "$val" ] && info "env $v" "$val"
done

if [ "$SKIP_NET" = "1" ]; then
  skip "Egress reachability" "SKIP_NET=1"
else
  chk_url() {
    CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$2" 2>/dev/null)
    case "$CODE" in
      000) bad "Egress: $1" "unreachable ($2)" ;;
      # Any HTTP status proves the host reached the endpoint. 404 from
      # swscan.apple.com, for example, is a normal reachable response.
      2*|3*|4*) ok "Egress: $1" "reachable (HTTP $CODE)" ;;
      5*) warn "Egress: $1" "reachable but server returned HTTP $CODE" ;;
      *) warn "Egress: $1" "HTTP $CODE ($2)" ;;
    esac
  }
  chk_url "Appcircle server" "$APPCIRCLE_URL"
  chk_url "VM image storage" "https://storage.googleapis.com/appcircle-dev-common/self-hosted/"
  chk_url "Appcircle CDN" "https://cdn.appcircle.io/self-hosted/harden-macos-host.sh"
  chk_url "GitHub" "https://github.com"
  chk_url "Homebrew" "https://formulae.brew.sh"
  chk_url "Apple software update" "https://swscan.apple.com"
  chk_url "CocoaPods CDN" "https://cdn.cocoapods.org"
fi

# ==============================================================================
section "9. tart and VM images"
# ==============================================================================
if command -v tart >/dev/null 2>&1; then
  ok "tart" "$(tart --version 2>&1 | head -n1) at $(command -v tart)"
  VMS=$(tart list 2>&1)
  if echo "$VMS" | grep -q "Name"; then
    # Do not assume the images are literally named vm01/vm02 - real hosts use
    # names like vm01.240514.self-automation. Anything that is neither a
    # downloaded macOS_YY0M0D image nor an ephemeral <name>-<uuid> clone is a
    # candidate base image.
    BASES=$(echo "$VMS" | awk 'NR>1{print $2}' \
            | grep -vE '^macOS_' \
            | grep -vE -- '-[0-9a-f]{8}-[0-9a-f]{4}-' || true)
    if [ -n "$BASES" ]; then
      ok "Base images" "$(echo "$BASES" | wc -l | tr -d ' ') found"
      echo "$BASES" | sed 's/^/             /'
    else
      bad "Base images" "none found - clone one from the downloaded macOS image first"
    fi

    DOWNLOADED=$(echo "$VMS" | awk 'NR>1{print $2}' | grep -E '^macOS_' | tr '\n' ' ')
    [ -n "$DOWNLOADED" ] && info "Downloaded images" "$DOWNLOADED" \
                         || warn "Downloaded images" "no macOS_YY0M0D image found"
    RUNNING=$(echo "$VMS" | grep -cE -- '-[0-9a-f]{8}-[0-9a-f]{4}-')
    info "Ephemeral instances" "$RUNNING present"
    [ "$RUNNING" -gt 2 ] && warn "Instance leak" "$RUNNING instances - Apple allows max 2 concurrent VMs"
    echo "$VMS" | sed 's/^/        /'
  else
    warn "tart list" "failed: $(echo "$VMS" | head -n1)"
  fi
else
  bad "tart" "not installed or not on PATH"
fi

command -v pigz >/dev/null 2>&1 && ok "pigz" "installed" || warn "pigz" "missing - needed to extract VM images"
command -v brew >/dev/null 2>&1 && ok "Homebrew" "$(brew --version 2>/dev/null | head -n1)" || warn "Homebrew" "not installed"

XC=$(ls "$RUNNER_HOME"/images/*.dmg 2>/dev/null | wc -l | tr -d ' ')
[ "${XC:-0}" -gt 0 ] && ok "Xcode images" "$XC dmg(s) in $RUNNER_HOME/images" \
                     || warn "Xcode images" "none found in $RUNNER_HOME/images"

# ==============================================================================
section "10. Runner lifecycle"
# ==============================================================================
# Find runner directories from the things that actually define one: the
# installed services and the running processes. Guessing from directory names
# both misses real runners (a layout like $HOME/runners/<name>/) and invents
# fake ones (any scratch directory that happens to hold a run.sh). The
# filesystem scan stays as a fallback, two levels deep to cover both layouts.
RUNNER_DIRS=""
add_runner_dir() {
  case " $RUNNER_DIRS " in *" $1 "*) return 0 ;; esac
  RUNNER_DIRS="$RUNNER_DIRS $1"
}

for p in $AC_DAEMONS $AC_AGENTS; do
  d=$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" "$p" 2>/dev/null)
  [ -n "$d" ] && add_runner_dir "$(dirname "$d")"
done
while IFS= read -r d; do
  [ -n "$d" ] && add_runner_dir "$d"
done < <(pgrep -fl 'run\.sh' 2>/dev/null | grep -v 'check-runner-host' \
         | sed -n 's#.*[[:space:]]\(/[^[:space:]]*\)/run\.sh.*#\1#p')
ACTIVE_DIRS="$RUNNER_DIRS"

# Anything else on disk holding a run.sh is reported as a count, not checked.
# A long-lived host accumulates old and archived copies - one had 29 - and
# running the full checks over them buries the runner that is actually in use.
IDLE_N=0
for d in "$RUNNER_HOME"/*/run.sh "$RUNNER_HOME"/*/*/run.sh; do
  [ -f "$d" ] || continue
  d=$(dirname "$d")
  case " $ACTIVE_DIRS " in *" $d "*) continue ;; esac
  IDLE_N=$((IDLE_N + 1))
done

FOUND=0
for d in $ACTIVE_DIRS; do
  [ -d "$d" ] || continue
  FOUND=$((FOUND + 1))
  N=$(basename "$d")
  [ -x "$d/run.sh" ] && ok "$N/run.sh" "present and executable  ($d)" \
                     || bad "$N/run.sh" "missing or not executable  ($d)"
  [ -f "$d/.stop" ] && warn "$N/.stop" "PRESENT - runner will not spawn new instances" \
                    || ok "$N/.stop" "absent"
done

if [ "$FOUND" = 0 ]; then
  bad "Runner directories" "no runner is installed as a service or currently running"
  [ "$IDLE_N" -gt 0 ] && detail "$IDLE_N unused directory(ies) under $RUNNER_HOME also contain a run.sh"
else
  [ "$IDLE_N" -gt 0 ] && \
    info "Other run.sh copies" "$IDLE_N unused directory(ies) under $RUNNER_HOME - not supervised, not checked"
fi

PROCS=$(pgrep -fl 'run\.sh' 2>/dev/null | grep -v 'check-runner-host')
if [ -n "$PROCS" ]; then
  ok "run.sh processes" "$(echo "$PROCS" | wc -l | tr -d ' ') running"
  echo "$PROCS" | sed 's/^/        /'
else
  bad "run.sh processes" "none running - runners are offline"
fi

SCR=$(screen -ls 2>/dev/null | grep -c Detached)
[ "${SCR:-0}" -gt 0 ] \
  && warn "screen sessions" "$SCR detached - current model, does not survive logout or reboot" \
  || info "screen sessions" "none"

# A system LaunchDaemon is the supported way to supervise a runner, and is what
# `runner-service.sh install` creates. Validate the keys that actually decide
# whether it works at boot.
plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

if [ -n "$AC_DAEMONS" ]; then
  ok "Host LaunchDaemons" "$(echo "$AC_DAEMONS" | wc -l | tr -d ' ') installed in /Library/LaunchDaemons"
  for p in $AC_DAEMONS; do
    L=$(plist_get "$p" Label)
    L=${L:-$(basename "$p" .plist)}
    detail "$p"

    if launchctl print "system/$L" >/dev/null 2>&1; then
      D_PID=$(launchctl print "system/$L" 2>/dev/null \
        | awk -F'=' '/^[[:space:]]*pid[[:space:]]*=/ {gsub(/[^0-9]/,"",$2); print $2; exit}')
      ok "  $L" "loaded in system domain${D_PID:+, pid $D_PID}"
      [ -z "$D_PID" ] && warn "  $L" "loaded but not running - check its StandardErrorPath"
    elif launchctl print-disabled system 2>/dev/null | grep -q "\"${L}\" => disabled"; then
      # A persistent disabled override, typically left by `launchctl unload -w`.
      # The plist is present and looks fine, but launchd will skip it at boot.
      bad "  $L" "installed but DISABLED - it will not start at boot (sudo launchctl load -w $p)"
    else
      bad "  $L" "installed but not loaded (sudo launchctl load -w $p)"
    fi

    # Runs as the runner account, not root: tart must see the same ~/.tart and
    # the same keychain it does interactively.
    D_USER=$(plist_get "$p" UserName)
    case "$D_USER" in
      "")     bad  "  $L UserName" "not set - the job would run as root and miss the runner's tart state" ;;
      root)   bad  "  $L UserName" "root - tart will not find the runner's ~/.tart or keychain" ;;
      *)      ok   "  $L UserName" "$D_USER" ;;
    esac

    # launchd does not read .zshrc, so Homebrew's bin dir must be declared or
    # tart is simply not found at boot.
    D_PATH=$(plist_get "$p" "EnvironmentVariables:PATH")
    case "$D_PATH" in
      *"/opt/homebrew/bin"*|*"/usr/local/bin"*) ok "  $L PATH" "includes the Homebrew prefix" ;;
      "")   bad "  $L PATH" "no EnvironmentVariables:PATH - launchd will not find tart" ;;
      *)    bad "  $L PATH" "does not include a Homebrew prefix: $D_PATH" ;;
    esac

    [ "$(plist_get "$p" RunAtLoad)" = "true" ] \
      && ok   "  $L RunAtLoad" "true - starts at boot" \
      || bad  "  $L RunAtLoad" "not true - will not start after a reboot"

    plist_get "$p" KeepAlive >/dev/null 2>&1 \
      && ok   "  $L KeepAlive" "set - restarts if it exits" \
      || warn "  $L KeepAlive" "not set - a crashed runner stays down"

    # KeepAlive:SuccessfulExit=false exists so a graceful `.stop` is honoured.
    # StartInterval would restart the cleanly exited job anyway and defeat it.
    if [ "$(plist_get "$p" "KeepAlive:SuccessfulExit")" = "false" ] \
       && plist_get "$p" StartInterval >/dev/null 2>&1; then
      warn "  $L StartInterval" "set alongside KeepAlive:SuccessfulExit=false - graceful stop will not hold"
    fi
  done
elif [ -n "$AC_AGENTS" ]; then
  warn "Supervision" "LaunchAgents found instead of LaunchDaemons - agents need a GUI session to exist"
  for p in $AC_AGENTS; do
    L=$(plist_get "$p" Label)
    L=${L:-$(basename "$p" .plist)}
    launchctl print "gui/$RUNNER_UID/$L" >/dev/null 2>&1 \
      && ok  "  agent $L" "loaded in gui/$RUNNER_UID" \
      || bad "  agent $L" "installed but not loaded in gui/$RUNNER_UID"
    plist_get "$p" "EnvironmentVariables:PATH" >/dev/null 2>&1 \
      || detail "$L has no EnvironmentVariables:PATH - launchd will not find tart"
  done
else
  bad "Supervision" "no io.appcircle.* LaunchDaemon or LaunchAgent - nothing restarts the runners after logout or reboot"
  detail "Install one with: cd \$HOME/runner1 && sudo ./runner-service.sh install vm01"
fi

# ==============================================================================
printf "\n${c_b}== Summary${c_0}\n"
printf "  ${c_g}%d passed${c_0}   ${c_y}%d warnings${c_0}   ${c_r}%d failures${c_0}\n" "$PASS" "$WARN" "$FAIL"

case "$MODE" in
  daemon) printf "  Supervision: system LaunchDaemon (supported)\n" ;;
  agent)  printf "  Supervision: gui-domain LaunchAgent - needs a logged-in session; a LaunchDaemon is preferred\n" ;;
  screen) printf "  Supervision: screen only - will not survive SSH logout or reboot\n"
          printf "               Fix: cd \$HOME/runner1 && sudo ./runner-service.sh install vm01\n" ;;
  none)   printf "  Supervision: none detected - no runner is being supervised\n" ;;
esac

if [ "$FAIL" -gt 0 ]; then
  printf "\n${c_r}Blocking issues${c_0}\n%s" "$FAIL_LIST"
fi
if [ "$WARN" -gt 0 ]; then
  printf "\n${c_y}Review these${c_0}\n%s" "$WARN_LIST"
fi

printf "\n"
if [ "$FAIL" -gt 0 ]; then
  echo "Result: NOT READY for unattended operation. Resolve the blocking issues above."
  exit 1
fi
if [ "$WARN" -gt 0 ]; then
  echo "Result: OPERATIONAL but fragile. Review the warnings above."
  exit 0
fi
echo "Result: READY."
exit 0
