# appcircle-self-hosted-scripts

Appcircle.io self-hosted scripts repository that has helper scripts for installation, upgrade, or runtime.

## Script Overviews

### `check-appcircle-server-update` Script

This script was made for checking the latest Appcircle server version, compare with the current installed, update if new versions found.

With this script, you can automate the update process of the Appcircle server with a cronjob.

To use that script, save it in the Appcircle server. Set the `AC_SERVER_PATH` environment variable to the path to the Appcircle server.

Edit the `environment` file of the system.

```bash
sudo vim /etc/environment
```

Declare the `AC_SERVER_PATH` variable.

```bash
AC_SERVER_PATH="/home/ubuntu/appcircle-server"
```

Check the variable.

```bash
echo $AC_SERVER_PATH
/home/ubuntu/appcircle-server
```

Run the script with your Appcircle project name. For example "spacetech"

```bash
./check-appcircle-server-update.sh -n "spacetech"
```

You can also create a cronjob.

```bash
crontab -e
```

Declare the cronjob. To schedule a cron job to run at 03:00 UTC every Saturday, you can use the following crontab entry:

```bash
0 3 * * 6 /home/ubuntu/check-appcircle-server-update.sh -n "spacetech" &>> /home/ubuntu/appcircle-server-update-cronjob.log
```

> [!CAUTION]
> Edit the full path of the script and edit the project name.

### `download-appcircle-server.sh`

You can use that script to download the latest Appcircle Server package.

Save the script to a directory.
Save the `cred.json` file to the same directory.

Run the script with no argument.

```bash
./download-appcircle-server.sh
```

This will download the latest and licensed Appcircle server for your `cred.json` file.
