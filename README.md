# appcircle-self-hosted-scripts

Appcircle.io self-hosted scripts repository that has helper scripts for installation, upgrade, or runtime.

## Script Overviews

### `install_vm` Script

This script was made for downloading, validating and extracting the Appcircle runner VM image tar.gz file in the background.

The curl command under the [Download MacOS VM](https://docs.appcircle.io/self-hosted-appcircle/self-hosted-runner/runner-vm-setup#download-macos-vm) can exit if user closes the ssh session.

The download and unzip takes so much time. So we this script handles manual tasks for the user.
