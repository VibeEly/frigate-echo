# Echo For Frigate

Echo enables the offsite shipment of Frigate alerts.

Echo provide a recourse in the event that a burglary results in damage or theft of the equipment running Frigate. 

Because Frigate stores video footage using it's own internal schema, there isn't an easy nor efficient way to sync internal Frigate data with an offsite store. To help enable offsite syncing, Echo does the following:

1. Watches for Frigate alerts via MQTT.
2. (Optionally) Ignore the alert if anyone is home according to Home Assistant.
3. Export video of the event from Frigate and move it to a local, synced, or remotely mounted folder.
4. (Optionally) Offsite backup to remotely hosted server via rsync SSH.

Echo now includes the optional feature send data offsite via rsync SSH. The local backup folder can also be tied to a remote service like [Syncthing](https://github.com/linuxserver/docker-syncthing), Dropbox, or a remote mount.

## Setup

### MQTT

An MQTT broker, like [Mosquitto](https://hub.docker.com/_/eclipse-mosquitto), is required if you are not already running one. 

Once the broker is up and running, you can configure Frigate to send alert information to it by adding the following to the Frigate configuration:

```yaml
mqtt:
  host: 192.168.0.10
  port: 1883
  topic_prefix: frigate
  client_id: frigate
  user: ''
  password: ''
```

You may also need to go under Settings > Notifications in the Frigate UI and confirm that notifications are enabled for cameras.

### Docker compose

#### docker-compose.yml
```
services:
  frigate-echo:
    image: tboyk/frigate-echo:latest
    restart: unless-stopped
    container_name: frigate-echo
    environment:
      - TZ=America/Los_Angeles
    volumes:
      - /usr/local/frigate-echo:/echo/config
      - /usr/local/frigate/exports:/mnt/frigate_exports
      - /usr/local/syncthing:/mnt/echo_storage
```

Specifically:

* Set the timezone so that the exported filenames show timestamps for your region.
* Set the three volumes. 
    * Map the folder with `config.yml`, `id_rsync`, and `known_hosts` that you create below to `/echo/config`
    * The first should map the Frigate exports folder to `/mnt/frigate_exports`. 
    * The second should map your offsite synced folder to `/mnt/echo_storage`.

#### config.yml
```
retention_days: 7

mqtt:
  server: "192.168.0.10"
  topic: "frigate/reviews"

home_assistant:
  url: "http://192.168.0.10:8123"
  token: "<long-lived-access-token>"

frigate:
  url: "http://192.168.0.10:5000"
  api_key: null

remote_backup:
  host: "backup.example.com"
  user: "echo"
  path: "/remote/backups/frigate-echo"
  port: 22
  identity_file: "/echo/config/id_rsync"
  known_hosts_file: "/echo/config/known_hosts"
  strict_host_key_checking: true
```

A few notes:

* `home_assistant`: Optionally prevent exporting of alerts when home assistant shows that someone is home. The `token` sub-key can be generated from within the Home Assistant UI by clicking on your name in the lower left corner, selecting the security tab, and then scrolling to the "Long-lived access tokens" section. Otherwise, comment or remove this section.

* `retention_days`: Optionally remove exports from the synced folder once they are the defined number of days old. Otherwise, comment or remove this key.

* `remote_backup`: Optionally send a copy of every exported clip to a remote server over `rsync` (via SSH) as soon as it lands in Echo storage. This is an additional, offsite copy on top of whatever you point `echo_storage` at — it's best-effort, so if the remote server is unreachable the clip stays safely in local Echo storage and Echo just logs a warning and carries on. Comment out or remove this section to disable it.
    * `host` : Remote host domain name or IP address. 
    * `user` : Remote user account for SSH.
    * `path`: Remote backup directory on the remote host that the `user` account can write to.
    * `port`: SSH port on the remote host (defaults to `22`).
    * `identity_file`: Path to a private SSH key used to authenticate. **Only key-based auth is supported** — Echo runs rsync in SSH "batch mode," so a server that requires a password will fail the connection instead of hanging on a prompt. Generate a dedicated key pair for this (e.g. `ssh-keygen -t ed25519 -f id_rsync -N ""`), mount the private key into the container (alongside `config.yml` is fine), and add the public key to `~/.ssh/authorized_keys` for that user on the backup server. Keep the private key's permissions restrictive (`chmod 600`).
    * `known_hosts_file`: Optional path to a `known_hosts` file containing the backup server's host key. If omitted, the default SSH known_hosts lookup is used. Either way, the host must already be known/trusted before the first backup — SSH into the backup server manually once (or run `ssh-keyscan` into a known_hosts file) so its key gets recorded; this prevents Echo from silently talking to an impostor server.
    * `strict_host_key_checking`: Defaults to `true` and should normally be left alone; it's what makes the `known_hosts` check above actually enforced. Only set to `false` if you understand and accept the risk of skipping host verification.


#### Starting it up

Create and run the docker image by executing the following from within the project folder:

`docker compose up -d`

You can check for issues by running:

`docker logs frigate-echo`