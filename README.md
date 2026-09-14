# appcircle-self-hosted-scripts

Appcircle.io self-hosted scripts repository that has helper scripts for installation, upgrade, or runtime.

## Script Overviews

### `download-runner.sh`

This script was made for downloading, validating and extracting the Appcircle runner VM image and Xcode image tar.gz files in the background.

The curl command under the [Download MacOS VM](https://docs.appcircle.io/self-hosted-appcircle/self-hosted-runner/runner-vm-setup#download-macos-vm) can exit if user closes the SSH session.

The download and unzip takes so much time. So this script handles manual tasks for the user.

For detailed usage, check the [docs](https://docs.appcircle.io/self-hosted-appcircle/self-hosted-runner/runner-vm-setup#download-macos-vm).

### `download-server.sh`

You can use that script to download the latest Appcircle server package.

Save the script to a directory.
Save the `cred.json` file to the same directory.

Run the script with no argument.

```bash
./download-server.sh
```

This will download the latest and licensed Appcircle server for your `cred.json` file.

### `harden-host.sh`

Applies a security baseline to the physical macOS host that runs the Tart VMs,
based on a subset of the CIS macOS Level 1 benchmark. Audit-only and dry-run
modes are available. Published as `harden-macos-host.sh` (see Publishing).

For detailed usage, check the [docs](https://docs.appcircle.io/self-hosted-appcircle/self-hosted-runner/configure-runner/macos-host-hardening).

### `run.sh`

The ephemeral runner loop for a Tart macOS VM. Clones the base VM, runs the
clone until the build finishes, deletes the clone and repeats. Started either
manually or, preferably, by `runner-service.sh`.

Beyond the loop it prepares the host for an unattended start: waits for `tart`
and for outbound networking to become usable at boot, removes clones orphaned
by a crash or a hard stop, and unlocks the login keychain.

That last step is what lets a runner survive a host reboot with nobody logged
in. On macOS 15 and newer, `tart` cannot read the Virtualization.framework
HostKey unless the runner account's login keychain is unlocked, and fails with
`VZErrorDomain Code=-9` otherwise. Put the keychain password in a mode-600 file
owned by the runner account and `run.sh` performs the unlock itself:

```bash
mkdir -p ~/.appcircle && chmod 700 ~/.appcircle
printf '%s' '<keychain-password>' > ~/.appcircle/runner-keychain.pw
chmod 600 ~/.appcircle/runner-keychain.pw
```

Override the path, never the secret, with `KEYCHAIN_PW_FILE`. Without the file
the unlock is skipped, which is correct on macOS 13 and when a desktop session
has already unlocked the keychain.

### `runner-service.sh`

Installs `run.sh` as a per-runner launchd system daemon so the runners start at
boot and are unaffected by an SSH session being closed. The service label is
derived from the runner folder name, so `$HOME/runner1` becomes
`io.appcircle.runner1` and several runners on one host get independent
services.

```bash
sudo ./runner-service.sh install <vm-name>
sudo ./runner-service.sh stop [--now] [--disable]
./runner-service.sh status
./runner-service.sh logs
```

### `check-runner-host.sh`

Read-only readiness check for a runner host. Reports PASS, WARN or FAIL per
item and exits non-zero on any failure. Covers sizing, MDM policy and password
rotation, desktop session and keychain state, auto-login and FileVault, power
settings, automatic updates, security posture, corporate root CA trust and TLS
interception, egress reachability, Tart and VM images, and runner supervision.

Run it before opening a support ticket about a runner that will not start.

## Publishing

The scripts are served to customers from `https://cdn.appcircle.io/self-hosted/`
and the documentation links to that URL. Publishing is manual, so the mapping
below is the only record of which repository file becomes which public file.
Keep it accurate.

| Repository file | Published as |
| --- | --- |
| `download-runner.sh` | `https://cdn.appcircle.io/self-hosted/download-runner.sh` |
| `harden-host.sh` | `https://cdn.appcircle.io/self-hosted/harden-macos-host.sh` |
| `run.sh` | `https://cdn.appcircle.io/self-hosted/run.sh` |
| `runner-service.sh` | `https://cdn.appcircle.io/self-hosted/runner-service.sh` |
| `check-runner-host.sh` | `https://cdn.appcircle.io/self-hosted/check-runner-host.sh` |

`download-server.sh` is not published to the CDN; it is delivered with the
server package instead.

`run.sh` must also be mirrored to
`https://storage.googleapis.com/appcircle-dev-common/self-hosted/run.sh`. That
URL is hardcoded in already-published documentation and in hosts installed
before the CDN existed, so moving it would break them.

Note the rename in the second row. `harden-host.sh` is published under a
different name than it has here, and nothing enforces that, so verify the
published URL after every upload.

## Testing

### Environment Information

- The tests should run in a clean environment.
- You can test overall functionality with bash script tests.
- You can see all the tests inside the `tests` folder.
- The ones with names ending with `*Test.sh` files are the **test cases** that are waiting to run.
- For example, to run tests for the `download-runner.sh`, you can simply call it:

```bash
./tests/download-runner-tests.sh
```

> :warning: **Warning**: The test scripts must be executed from the repo's root directory. For instance, `./tests/download-runner-tests.sh`. The command running inside the `tests` folder as `./download-runner-tests.sh` will not work.

- You should see an output like:

```bash
You can see the outputs in ./tests/reports/test-6514-23621 folder
testRunnerDownload
test-6514-23621 test starting
Tests finished.

Ran 1 test.

OK
```

- If you face any errors while testing and want to see the outputs, please check the `./tests/reports` folder.
- Test outputs are written to that directory with the name of test id.

### Test Cases

- `download-runner-tests.sh`
  - **testRunnerDownload**
    - Valid remote MD5 for macOS images should be found.
    - MD5 check for macOS image should be successful.
    - Valid remote MD5 for Xcode images should be found.
    - MD5 check for Xcodes image should be successful.
    - MacOS image should be extracted successfully.
    - MacOS image directory should be found in the "$HOME/.tart/vms" directory.
    - Xcode images should be extracted successfully.
    - Xcode images directory should be found in the "$HOME" directory.
    - Xcode images directory should contain some dmg files.
    - Script output should container success log.
  - **testRunnerDownloadWithNonExistingVersion**
    - Script output should contain 404 logs 6 times.
    - Script output should contain fail log.
