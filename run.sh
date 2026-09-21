#!/usr/bin/env bash

VERSION="1.9.1"
if [ $# -ne 1 ]; then
    # print version
    echo "v$VERSION"
    exit 0
fi

set -eou pipefail

cd "$(dirname "$0")"

VMNAME=$1
UUID=""

# at the start of the script, clean up any old state files.  if a user wants to
# run multiple copies of this at once, each copy should deposit their own
# ".stopped" file when they are complete, and all should obey the .stop file,
# after it is `touch`ed in the same directory as this script.  placing multiple
# different .stopped files is not supported yet.  need to think of a clean-ish
# way to do this in Bash.
if [ -e .stop ]; then
    echo "rm .stop"
    rm .stop
fi

if [ -e .stopped ]; then
    echo "rm .stopped"
    rm .stopped
fi

function log() {
    echo "$(date) $1"
}

function getTartCmd() {
    local xcodePath="$HOME/images"

    local command="tart run $VMNAME-$UUID"
    command=${command}" --disk=$xcodePath/xcode.26.3.dmg:ro"
    command=${command}" --disk=$xcodePath/xcode.26.4.dmg:ro"
    command=${command}" --disk=$xcodePath/xcode.26.5.dmg:ro"
    command=${command}" --disk=$xcodePath/xcode.26.6.dmg:ro"
    command=${command}" --no-graphics"

    echo "$command"
}

function startVM () {
    # launch that VM
    tartCmd=$(getTartCmd)

    log "$tartCmd"
    $tartCmd
}

function deleteVM () {
    # delete the runner VM we created above
    log "tart delete $VMNAME-$UUID"
    tart delete "$VMNAME-$UUID"
}

function tryStartVM () {
    log 'We got error when try to run the VM above, retry...'
    sleep 5
    local tryCount=1
    tartCmd=$(getTartCmd)
    until $tartCmd; do
        sleep 5
        ((tryCount++))
        # timeout: 30 min
        if [ "$tryCount" -eq 360 ]; then
            log 'Timeout! Check the log files for details.'
            deleteVM
            exit 1
        fi
        log 'Still got error when try to run the VM, retry...'
    done
}

# When this script is started by launchd at boot (see runner-service.sh) it can
# run before Homebrew's PATH is usable or before tart has settled. Wait instead
# of dying on the first attempt. Harmless when started manually.
function waitForTart () {
    local tryCount=0
    until command -v tart >/dev/null 2>&1 && tart list >/dev/null 2>&1; do
        sleep 5
        tryCount=$((tryCount + 1))
        # timeout: 5 min
        if [ "$tryCount" -ge 60 ]; then
            log 'tart is still not available after 5 minutes. Giving up.'
            exit 1
        fi
        log 'Waiting for tart to become available...'
    done
}

# A reboot, a crash or a hard service stop leaves "<vm>-<uuid>" clones behind,
# because deleteVM never got to run. They waste disk and count against Apple's
# limit of two concurrent macOS VMs per host, so the next start would fail.
function cleanupOrphans () {
    if pgrep -f "tart run ${VMNAME}-" >/dev/null 2>&1; then
        log "A tart process for ${VMNAME} is already running, skipping orphan cleanup."
        return 0
    fi

    local orphan
    while IFS= read -r orphan; do
        [ -n "$orphan" ] || continue
        log "Deleting orphaned VM clone: ${orphan}"
        tart delete "$orphan" || log "Could not delete ${orphan}"
    done < <(tart list 2>/dev/null | awk -v pat="^${VMNAME}-" '$2 ~ pat {print $2}')
}

# launchd starts this very early at boot, before the host has working outbound
# networking. A guest that boots without one cannot reach NTP, so it keeps the
# date frozen into the base image at snapshot time. With a clock months in the
# past, TLS to the Appcircle API fails ("The SSL connection could not be
# established"), the runner never registers, and the agent silently never
# appears in the panel even though the VM is up and has an IP.
#
# Override the probe with NET_CHECK_HOST / NET_CHECK_PORT in the service
# plist's EnvironmentVariables when the host has no route to the default.
NET_CHECK_HOST="${NET_CHECK_HOST:-www.apple.com}"
NET_CHECK_PORT="${NET_CHECK_PORT:-443}"

function waitForNetwork () {
    local tryCount=0
    until nc -z -G 3 "$NET_CHECK_HOST" "$NET_CHECK_PORT" >/dev/null 2>&1; do
        sleep 5
        tryCount=$((tryCount + 1))
        # Do not block boot forever: an air-gapped host would never pass this.
        if [ "$tryCount" -ge 24 ]; then
            log "Network still unreachable (${NET_CHECK_HOST}:${NET_CHECK_PORT}) after 2 minutes. Starting the VM anyway."
            log 'If the guest clock is wrong, its TLS calls will fail. Set NET_CHECK_HOST to something reachable.'
            return 0
        fi
        log "Waiting for host network (${NET_CHECK_HOST}:${NET_CHECK_PORT})..."
    done
    log 'Host network is up.'
}

# On macOS 15 and newer, Virtualization.framework can only mint the tart
# HostKey when a file-based login keychain is present and unlocked. A desktop
# login normally does that unlock, which is why the daemon appeared to need
# auto-login. It does not: the daemon can perform the same unlock itself, and
# a host with this configured was measured running unattended on macOS 26.6.2
# through a reboot with neither an SSH nor a desktop login.
#
# Without it tart fails with:
#   VZErrorDomain Code=-9 "The virtual machine encountered a security error."
#   Failed to get current host key. / Failed to create new HostKey.
#
# KEYCHAIN_PW_FILE holds the keychain password, mode 600, owned by the runner
# user. Override the path - never the secret itself - through the service
# plist's EnvironmentVariables: the plist is world readable.
#
# No-op on macOS 13, where tart needs no session at all, and under the manual
# `screen` method, where the SSH login has already unlocked the keychain.
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
KEYCHAIN_PW_FILE="${KEYCHAIN_PW_FILE:-$HOME/.appcircle/runner-keychain.pw}"

function ensureKeychain () {
    if [ ! -f "$KEYCHAIN_PW_FILE" ]; then
        log "No keychain password file at ${KEYCHAIN_PW_FILE}, skipping keychain unlock."
        log 'On macOS 15 or newer tart fails with "Failed to get current host key" unless a desktop session has already unlocked the keychain.'
        return 0
    fi

    local pw
    pw=$(cat "$KEYCHAIN_PW_FILE")

    if [ ! -f "$KEYCHAIN" ]; then
        # A runner account that has never been logged into interactively has no
        # login keychain at all, so create it rather than failing the unlock.
        log "Login keychain missing, creating ${KEYCHAIN}"
        security create-keychain -p "$pw" "$KEYCHAIN"
        if [ ! -f "$KEYCHAIN" ]; then
            log "create-keychain did not produce ${KEYCHAIN}. Aborting."
            exit 1
        fi
        security default-keychain -d user -s "$KEYCHAIN"
        security login-keychain -d user -s "$KEYCHAIN" 2>/dev/null || true
    fi

    # -s replaces the entire search list, so re-state the current entries
    # instead of dropping every other keychain the account has.
    if ! security list-keychains -d user | tr -d ' "' | grep -qx "$KEYCHAIN"; then
        local current
        current=$(security list-keychains -d user | tr -d ' "' | tr '\n' ' ')
        # shellcheck disable=SC2086
        security list-keychains -d user -s $current "$KEYCHAIN"
    fi

    if ! security unlock-keychain -p "$pw" "$KEYCHAIN"; then
        log "Failed to unlock ${KEYCHAIN}. Check the password in ${KEYCHAIN_PW_FILE}."
        exit 1
    fi

    # Neither -t nor -l: never lock on an idle timeout, never lock on sleep.
    # Skipping this is the trap that makes the failure look intermittent - the
    # first build after a boot passes and the keychain relocks before the next.
    security set-keychain-settings "$KEYCHAIN"

    if ! security show-keychain-info "$KEYCHAIN" >/dev/null 2>&1; then
        log "Keychain still reports locked after unlock: ${KEYCHAIN}"
        exit 1
    fi
    log "Keychain unlocked with no auto-lock: ${KEYCHAIN}"
}

# These run before the redirected block below, so their output lands in the
# launchd service log where a failure to start is actually visible.
waitForTart
ensureKeychain
waitForNetwork
cleanupOrphans

{
    # while the .stop file does _not_ exist:
    while [ ! -e .stop ]; do
        # come up with a unique suffix
        UUID=$(uuidgen | tr "[:upper:]" "[:lower:]")
        
        log "UUID: $UUID"

        # clone the runner VM to a VM named with the new suffix
        log "tart clone $VMNAME $VMNAME-$UUID"
        tart clone "$VMNAME" "$VMNAME-$UUID"

        if ! startVM; then
            tryStartVM
        fi

        deleteVM
    done
# Append rather than truncate. The service restarts run.sh on a non-zero exit,
# and truncating here would erase the output of the failure that caused the
# restart, leaving a crash loop with no evidence. `runner-service.sh install`
# resets these files, which is what bounds their growth.
} >> stdout.log 2>> stderr.log

# if we see the ".stop" file, the `while` loop is broken and then this code is
# run.  This places a .stopped file in the directory of the script to show that
# this wrapper script has exited.
echo "echo \".\" >> .stopped"
echo "." >> .stopped
