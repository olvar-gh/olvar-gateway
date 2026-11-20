# Deploying Olvar: Supabase + Raspberry Pi gateway

This guide takes you from nothing to readings arriving in Supabase. Do the steps in order and copy the commands
exactly. Text in `<angle brackets>` is a value you replace, without the brackets.

- **Part A** runs on your own computer (Mac, Linux or Windows with WSL). It sets up the hosted Supabase project.
- **Part B** runs on the Raspberry Pi 3B, over SSH. The Pi only runs the gateway and the MQTT broker: no desktop,
  no kiosk, no Docker.

Daily operations (logs, updates, passwords, replacing a device) are in [RUNBOOK.md](RUNBOOK.md).

## What you need

- A Supabase account and an organization to create the project in.
- An Anthropic Console account with some prepaid credit (console.anthropic.com). The chat uses Claude Sonnet 5.5.
- A Raspberry Pi 3B, a good microSD card (16 GB or more, A1/A2 class), the official 5 V 2.5 A power supply.
- The ESP32 plant sensor, flashed with the Olvar firmware, and a USB cable to read its serial log.
- On your computer: `git`, and a terminal.

Write these down somewhere safe as you go (a password manager is ideal). None of them ever goes into git.

| Name | Where it comes from |
|---|---|
| Database password | Step A2 |
| Project ref (20 lowercase letters) | Step A2 |
| Project URL `https://<project-ref>.supabase.co` | Step A2 |
| Secret key `gateway` (`sb_secret_…`) | Step A3 |
| Owner email and password (your dashboard login) | Step A7 |
| Anthropic API key (`sk-ant-…`) | Step A6 |
| MQTT password for `olvar-gateway` | Step B5 |
| MQTT password for the ESP32 | Step B7 |

---

## Part A: Supabase (on your computer)

### A1. Install the Supabase CLI (version 3)

macOS (with Homebrew):

```sh
brew install supabase/tap/supabase
supabase --version
```

On Linux or WSL, follow https://supabase.com/docs/guides/cli/getting-started and then run `supabase --version`.

The version must start with `3.`. If it starts with `2.`, run `brew upgrade supabase` (or reinstall).

In CLI v3, database commands work on your *local* copy unless you add `--remote`. Every command below that
changes the hosted project asks "Do you want to continue?" with **No** as the default: type `y` and press Enter.

### A2. Create the project in your organization

1. Open https://supabase.com/dashboard and sign in.
2. Click **New project**.
3. **Organization:** choose your organization.
4. **Project name:** `olvar`.
5. **Database password:** click **Generate a password**, copy it and save it.
6. **Region:** the one closest to you.
7. Plan: **Free**.
8. Under **Security options**, make sure **Automatically expose new tables** is **off**.
9. Click **Create new project** and wait until the dashboard says the project is ready (1–2 minutes).
10. Open **Project Settings → General** and copy the **Project ID**. This is your *project ref*.
    Your *project URL* is `https://<project-ref>.supabase.co`.

### A3. Create the secret key for the Pi

1. Open **Project Settings → API Keys**.
2. Under **Secret keys**, click **Add new secret key**.
3. Name: `gateway`. Create it.
4. Click the eye icon, copy the key (it starts with `sb_secret_`) and save it.

This key bypasses all row security. It goes only into the Pi's `/etc/olvar-gateway/gateway.env`, never into the
dashboard app, a chat message or git.

### A4. Get the code and link it to the project

```sh
git clone https://github.com/olvar-gh/olvar-gateway.git
cd olvar-gateway
git -c advice.detachedHead=false checkout v0.1.0     # the newest release tag; see CHANGELOG.md
supabase login
```

`supabase login` opens a browser window; approve it. Then check that the CLI sees your project in your
organization:

```sh
supabase orgs list
supabase projects list
```

Find the row named `olvar` whose organization is yours, and use its reference id:

```sh
supabase link --project-ref <project-ref>
```

When it asks for the database password, paste the one from A2.

### A5. Create the database (migrations)

First see what will be applied, without changing anything:

```sh
supabase db push --remote --dry-run
```

You should see every file in `supabase/migrations`, from `20261116000100_core.sql` to the newest one
(`20261120000200_device_climate_sensor.sql` in v0.1.0). Now apply them:

```sh
supabase db push --remote
```

Answer `y`. Then check that every migration shows in the **Remote** column:

```sh
supabase migration list --remote
```

`db push` never runs `supabase/seed.sql`, so no test users or fake readings reach your project. The peace lily
profile is created by a migration, so it is there now.

### A6. Give the chat function its Anthropic key, then deploy it

1. On https://console.anthropic.com, open **Settings → API keys → Create key**, name it `olvar`, copy it.
2. In the terminal, still inside `olvar-gateway`, run these lines one by one. The first one waits for you to paste
   the key; nothing is shown while you paste, which keeps it out of your shell history.

```sh
printf 'Anthropic API key: '; read -rs ANTHROPIC_API_KEY; echo
supabase secrets set ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
unset ANTHROPIC_API_KEY
supabase secrets list
```

Answer `y` to the confirmation. `secrets list` shows `ANTHROPIC_API_KEY` with a hash, never the key itself.

If the list also shows `DEEPSEEK_API_KEY`, this project ran the older DeepSeek chat. **Leave that secret in place
for now:** the running function still uses it until the deploy below succeeds and a real Claude reply has been
checked. Follow "Move the chat from DeepSeek to Claude" in [RUNBOOK.md](RUNBOOK.md) instead of the rest of this step.

Deploy the function (`--use-api` bundles it on Supabase's servers, so Docker is not needed):

```sh
supabase functions deploy chat --use-api
supabase functions list
```

Answer `y`. The list shows `chat` as `ACTIVE`. Leave JWT verification on: only the signed-in owner may call it.

### A7. Create the owner account and close sign-ups

1. Dashboard → **Authentication → Users → Add user → Create new user**.
2. Enter your email and a strong password, tick **Auto Confirm User**, click **Create user**.
   This is the login you will use in the Olvar app.
3. Dashboard → **Authentication → Sign In / Providers**: turn **Allow new users to sign up** **off** and save.

The plant and the device are created, and the gateway is given to this account, in step B8, once you know the
ESP32's device id.

---

## Part B: Raspberry Pi (over SSH)

### B1. Flash the SD card

1. Install **Raspberry Pi Imager** from https://www.raspberrypi.com/software/ and start it.
2. **Device:** Raspberry Pi 3.
3. **Operating system:** Raspberry Pi OS (other) → **Raspberry Pi OS Lite (64-bit)**.
4. **Storage:** your microSD card.
5. When it offers to customise the settings, choose **Edit settings**:
   - Hostname: `olvar-gw`
   - Username and password: pick your own (this guide writes `<pi-user>`)
   - Wireless LAN: your Wi-Fi name and password, and your country (skip if you use Ethernet)
   - Locale: your time zone and keyboard layout
   - **Services:** enable **SSH** with password authentication
6. Write the card, put it in the Pi and power it on. The first boot takes a few minutes.

### B2. Connect and update

From your computer:

```sh
ssh <pi-user>@olvar-gw.local
```

Type `yes` at the fingerprint question, then your Pi password. If `olvar-gw.local` is not found, look up the Pi's IP
address in your router and use `ssh <pi-user>@<pi-ip>`.

On the Pi:

```sh
sudo apt update
sudo apt full-upgrade -y
sudo reboot
```

Wait a minute and reconnect with the same `ssh` command.

In your router's settings, give the Pi a **DHCP reservation** (a fixed IP address). The ESP32 will connect to it.

### B3. Download the gateway

On the Pi, clone the repo and switch to the newest release tag (v0.1.0 is the first one), so the Pi runs exactly
the code that matches the migrations you pushed in A5:

```sh
sudo apt install -y git
git clone https://github.com/olvar-gh/olvar-gateway.git ~/olvar-gateway
git -C ~/olvar-gateway -c advice.detachedHead=false checkout v0.1.0
```

Use the same tag as on your computer in A4.

### B4. Install

```sh
cd ~/olvar-gateway
sudo deploy/install.sh
```

This takes 5–10 minutes on a Pi 3B. It installs Python, Mosquitto and nftables; creates the `olvar` system user,
the program in `/opt/olvar-gateway`, the settings file `/etc/olvar-gateway/gateway.env`, the systemd service, a
50 MB log cap, and a firewall rule that allows MQTT (port 1883) only from your home network.

It ends with **"Not started yet. Next:"**. That is expected: the next steps create the passwords.

If it stops with *could not detect the LAN subnet*, run it again with your network, for example
`sudo OLVAR_LAN_SUBNET=192.168.1.0/24 deploy/install.sh`.

### B5. MQTT user for the gateway (creates the password file)

The gateway logs in to Mosquitto as `olvar-gateway`. Choose a long password and save it.

`mosquitto_passwd -c` *creates* the password file and **erases any users already in it**, so it may only be used
when the file does not exist yet. This command checks that for you; paste it as one block:

```sh
if sudo test -f /etc/mosquitto/passwd; then
  sudo mosquitto_passwd /etc/mosquitto/passwd olvar-gateway
else
  sudo mosquitto_passwd -c /etc/mosquitto/passwd olvar-gateway
fi
sudo chown mosquitto:mosquitto /etc/mosquitto/passwd
sudo chmod 0600 /etc/mosquitto/passwd
```

Type the password twice. From now on, never use `-c` again. `mosquitto_passwd` prints *"owner is not root"*
warnings because the file belongs to `mosquitto`; that is the owner the broker requires, so ignore them.

### B6. Fill in the gateway settings

```sh
sudo nano /etc/olvar-gateway/gateway.env
```

Change these three lines (leave the others as they are):

```
SUPABASE_URL=https://<project-ref>.supabase.co
SUPABASE_SECRET_KEY=<the sb_secret_… key from A3>
MQTT_PASSWORD=<the olvar-gateway password from B5>
```

Save with **Ctrl+O**, Enter, and exit with **Ctrl+X**. Check the settings:

```sh
sudo -u olvar bash -c 'set -a; . /etc/olvar-gateway/gateway.env; /opt/olvar-gateway/venv/bin/python -m olvar_gateway --check-config'
```

It must end with `config ok`. Otherwise it lists what to fix.

### B7. Find the ESP32's device id

Connect the ESP32 to your computer with USB and open its serial monitor (see the firmware README). The boot log
shows the `device_id` (the serial command `status` prints it too), for example `olvar-a1b2c3`. Write it down; this guide calls it `<device-id>`.

### B8. Create the plant and the device, and claim the gateway, in Supabase

On the Pi, in `~/olvar-gateway`. Use the owner email from A7, the device id from B7, and your time zone as an IANA
name such as `Europe/Berlin`, `America/New_York` or `Asia/Seoul` (run `timedatectl` to see the Pi's):

```sh
cd ~/olvar-gateway
sudo /opt/olvar-gateway/venv/bin/python tools/setup_plant.py \
  --env-file /etc/olvar-gateway/gateway.env \
  --owner-email <owner-email> \
  --device-id <device-id> \
  --timezone <Area/City>
```

It also makes you the owner of this gateway: it reads `GATEWAY_ID` from the env file (`olvar-gw` unless you
changed it) and sets the owner of that row in `gateways`. Without this the dashboard shows the gateway as "not
seen yet" even though it is running, because only the owner may read the row. The output ends its summary with
`gateway: olvar-gw (owned by <owner-email>)`. The gateway's own heartbeat never touches the owner.

Optional: `--nickname Lily` and `--location "Living room window"`. You can run it again safely; it keeps the
same plant, the device's calibration and the gateway's heartbeat values. Possible errors:

- *migrations are missing* or *profile 'spathiphyllum' is missing*: do step A5 again.
- *no user with email …*: do step A7 (check the spelling).
- *gateway olvar-gw already belongs to another user*: this `GATEWAY_ID` is used by another account in the
  project. Give this Pi its own `GATEWAY_ID` in `/etc/olvar-gateway/gateway.env`, restart the gateway and run the
  command again.
- *unknown timezone*: use a name from the list at https://en.wikipedia.org/wiki/List_of_tz_database_time_zones.

### B9. MQTT user for the ESP32

Choose a password for the ESP32 and save it. The file exists now, so there is **no `-c`**:

```sh
sudo mosquitto_passwd /etc/mosquitto/passwd <device-id>
sudo chown mosquitto:mosquitto /etc/mosquitto/passwd
sudo chmod 0600 /etc/mosquitto/passwd
```

### B10. Start everything

```sh
sudo systemctl restart mosquitto olvar-gateway
systemctl status mosquitto olvar-gateway --no-pager
```

Both must show `active (running)` in green. Watch the gateway log (press **Ctrl+C** to stop watching):

```sh
journalctl -u olvar-gateway -f
```

You should see `mqtt connected` and `gateway olvar-gw started`, and no `heartbeat failed` line after the first
minute. `timedatectl` should say `System clock synchronized: yes`.

### B11. Point the ESP32 at the Pi

In the ESP32's setup (see the firmware README), enter:

| Setting | Value |
|---|---|
| Broker host | the Pi's reserved IP from B2 (or `olvar-gw.local`) |
| Port | `1883` |
| Username | `<device-id>` |
| Password | the ESP32 password from B9 |

### B12. Check that readings arrive

Within two minutes of the ESP32 starting:

```sh
sudo -u olvar /opt/olvar-gateway/venv/bin/python -m olvar_gateway status
```

`queue_depth` stays near 0 and `last_error` is `none`. In the Supabase dashboard, **Table Editor → readings**
shows new rows, **devices** shows your device as `online`, and **gateways** shows `olvar-gw` with your user id in
`owner_id` and a `last_seen_at` from the last five minutes.

Last step: calibrate the soil probe in the app's **Soil calibration** screen (dry value when the plant needs water,
wet value after a full watering has drained).

---

## Updating later

Releases are git tags such as `v0.1.0`; [CHANGELOG.md](../CHANGELOG.md) says what each one changes and whether it
has database migrations.

**Order matters: the database first, then the Pi.** A new gateway may write a column that only a new migration
creates. Until that migration is on the project, every device update fails (the gateway retries and backs off) and
readings slow down. So, for every release:

1. **On your computer**, in the checkout linked to the project (A4):

   ```sh
   cd olvar-gateway
   git fetch --tags
   git -c advice.detachedHead=false checkout <tag>
   supabase db push --remote --dry-run     # lists only the migrations this release adds
   supabase db push --remote               # answer y
   supabase migration list --remote        # every migration shows in the Remote column
   ```

   If the release changes the chat function (the changelog says so), also run
   `supabase functions deploy chat --use-api`.

2. **On the Pi:**

   ```sh
   cd ~/olvar-gateway
   sudo deploy/update.sh <tag>
   ```

   Without a tag it lists the newest ones. It checks out the tag, re-runs `install.sh` (pinned dependencies,
   config files) and restarts the gateway. Your `gateway.env` and MQTT passwords are kept. The output includes a
   line such as `olvar-gateway 0.1.0 (v0.1.0)`: the installed version and the tag.

3. **Check:** `sudo -u olvar /opt/olvar-gateway/venv/bin/python -m olvar_gateway status` shows `last_error: none`,
   and within five minutes the `gateways` row shows the new `version`.

### The first tagged update (to v0.1.0)

A Pi installed before v0.1.0 was cloned on the `main` branch and has never seen a tag. Move it to the tag once;
from then on it always sits on a tag:

1. On your computer, push the migrations as in step 1 above, with `<tag>` = `v0.1.0`. v0.1.0 adds
   `20261120000200_device_climate_sensor.sql` (the `devices.climate_sensor` column); the dry run must list it.
2. On the Pi:

   ```sh
   cd ~/olvar-gateway
   git status --short --untracked-files=no      # must print nothing; update.sh refuses local changes
   ls deploy/update.sh                          # missing on very old clones: run "git pull --ff-only" first
   sudo deploy/update.sh v0.1.0
   git describe --tags                          # v0.1.0
   ```

3. Check as in step 3 above: `gateways.version` is `0.1.0`. Once the ESP32 runs firmware that sends the sensor
   name, `devices.climate_sensor` shows `sht31` or `dht11`; with older firmware it stays empty (null).

If `update.sh` stops with *no tag named v0.1.0*, the tag is not published yet; wait for the release.

### Other fixes after an update

If the dashboard shows the gateway as "not seen yet" although `journalctl -u olvar-gateway` shows no
`heartbeat failed`, the gateway has no owner (installs set up before `setup_plant.py` claimed it). Run step B8
again with the same values; it changes nothing else.
