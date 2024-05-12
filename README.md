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
