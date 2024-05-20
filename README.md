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
