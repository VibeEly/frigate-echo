# Echo For Frigate

Echo enables the offsite shipment of Frigate alerts.

Echo provide a recourse in the event that a burglary results in damage or theft of the equipment running Frigate. 

Because Frigate stores video footage using it's own internal schema, there isn't an easy nor efficient way to sync internal Frigate data with an offsite store. To help enable offsite syncing, Echo does the following:

1. Watches for Frigate alerts via MQTT.
2. (Optionally) Ignore the alert if anyone is home according to Home Assistant.
3. Export video of the event from Frigate and move it to a local, synced, or remotely mounted folder.
4. (Optionally) Offsite backup to remotely hosted server via rsync SSH.

Echo now includes the optional feature to send data to an offsite server via rsync SSH. The local backup folder can also be tied to a remote service like [Syncthing](https://github.com/linuxserver/docker-syncthing), Dropbox, or a remote mount.

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
  username: ""
  password: ""

frigate:
  url: "http://192.168.0.10:5000"
  api_key: null
  export_start: 5
  export_end: 5
  # Only needed when using the authenticated port (8971) instead of 5000:
  # user: "echo"
  # password: "<password>"
  # verify_ssl: false   # 8971 uses a self-signed certificate by default


# Optional: Prevents exports when home. Remove section to disable.
home_assistant:
  url: "http://192.168.0.10:8123"
  token: "<long-lived-access-token>"
  # Optional: only check these entities instead of every person.* entity.
  # entities: ["person.alice", "person.bob"]

# Optional: Uploads exports via rsync. Remove section to disable.
remote_backup:
  host: "backup.example.com"
  user: "echo"
  path: "/mnt/backups/frigate-echo"
  identity_file: "/echo/config/id_rsync"
  known_hosts_file: "/echo/config/known_hosts"
  bandwidth_limit: 0
```

A few notes:

* `retention_days`: Optionally remove exports from the synced folder once they are the defined number of days old (0 or remove to keep exports forever). 

* `frigate`: Echo needs Frigate 0.15 or newer (older versions do not return an export id) and is written against the 0.18 API.
    * Port `5000` is Frigate's internal, unauthenticated port. Leave `user`, `password` and `api_key` unset and keep that port reachable only from trusted networks.
    * Port `8971` is the authenticated port. Create a user in Frigate (Settings > Users) and set `user` and `password`. Echo logs in, keeps the token and logs in again when it expires. Frigate serves a self-signed certificate on this port by default, so set `verify_ssl: false` unless you have installed a real certificate.
    * `api_key` : Frigate API key.
    * `export_start` : Seconds to include before the detected event (defaults to `5`).
    * `export_end` : Seconds to include after the detected event (defaults to `5`).

* `home_assistant`: Optionally prevent exporting of alerts when home assistant shows that someone is home. If Home Assistant cannot be reached, Echo exports the alert anyway. The `token` sub-key can be generated from within the Home Assistant UI by clicking on your name in the lower left corner, selecting the security tab, and then scrolling to the "Long-lived access tokens" section. Comment out or remove this section to disable it.

* `remote_backup`: Optionally send a copy of every exported clip to a remote server over rsync (via SSH) as soon as it lands in Echo storage. This is an additional, offsite copy on top of whatever you point `echo_storage` at — if the remote server is unreachable the clip stays safely in local Echo storage, Echo logs a warning, and it keeps retrying every minute until everything has been uploaded (including after a restart). Comment out or remove this section to disable it.
    * `host` : Remote host domain name or IP address. 
    * `user` : Remote user account for SSH.
    * `path`: Remote backup directory on the remote host that the `user` account can write to.
    * `port`: SSH port on the remote host (defaults to `22`).
    * **`identity_file`**: Path to a private SSH key used to authenticate. **Only key-based auth is supported** — Echo runs rsync in SSH "batch mode," so a server that requires a password will fail the connection. Generate a dedicated key pair for this (e.g. `ssh-keygen -t ed25519 -f id_rsync -N ""`), mount the private key into the container (alongside `config.yml` is fine), and add the public key to `~/.ssh/authorized_keys` for that user on the backup server. Keep the private key's permissions restrictive (`chmod 600`).
    * **`known_hosts_file`**: Optional path to a `known_hosts` file containing the backup server's host key. If omitted, the default SSH known_hosts lookup is used. The host must already be known/trusted before the first backup — SSH into the backup server manually once (or run `ssh-keyscan` into a known_hosts file) so its key gets recorded.
    * `strict_host_key_checking`: Defaults to `true` and should normally be left alone; it's what makes the `known_hosts` check above actually enforced. Only set to `false` if you understand and accept the risk of skipping host verification.
    * `bandwidth_limit`: Optionally limit upload bandwidth to remote server in KB/s kilobytes per second (defaults to unlimited `0`).


#### Syncthing notes

* Clips are copied into `echo_storage` as `<name>.mp4.part` and renamed when complete. If you sync that folder with Syncthing, add `*.part` to its `.stignore` so the temporary file is not synced.


#### Starting it up

Create and run the docker image by executing the following from within the project folder:

`docker compose up -d`

You can check for issues by running:

`docker logs frigate-echo`