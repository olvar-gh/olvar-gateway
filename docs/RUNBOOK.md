# Runbook: operating the Pi gateway

Commands run on the Pi over SSH (`ssh <pi-user>@olvar-gw.local`) unless they say otherwise. First-time setup is in
[DEPLOY.md](DEPLOY.md).

## Health check

```sh
systemctl status mosquitto olvar-gateway --no-pager
sudo -u olvar /opt/olvar-gateway/venv/bin/python -m olvar_gateway status
journalctl -u olvar-gateway --since "1 hour ago" --no-pager
timedatectl | grep synchronized
```

| What you see | Meaning | What to do |
|---|---|---|
| `queue_depth` grows, `last_error` mentions 401/403/`42501` | the secret key was deleted or rotated | create a new `gateway` key (DEPLOY.md A3), put it in `gateway.env`, restart |
| `last_error` mentions 404 or `PGRST`, or the log shows `device … update failed, will retry: schema 400 PGRST204` | migrations missing on the project (for example the Pi was updated before `db push`) | `supabase db push --remote` on your computer, at the same tag as the Pi (DEPLOY.md "Updating later") |
| `heartbeat failed: network …` | no internet or the Supabase project is paused | check the Pi's network; in the dashboard, **Restore project** if it is paused (Free projects pause after 7 days without activity) |
| `dead_letters` above 0 | some readings were rejected by the database | `journalctl -u olvar-gateway | grep dead` shows why; they are kept in the outbox file, not uploaded |
| `System clock synchronized: no` | no NTP yet | readings are held and stamped once the clock syncs; check the network |
| gateway `inactive (dead)` with `status=2` | invalid `gateway.env` | run the `--check-config` command from DEPLOY.md B6 and fix what it lists |

Readings are never lost while Supabase is unreachable: the outbox at `/var/lib/olvar-gateway/outbox.db` holds up to
100,000 readings (about 70 days for one device) and uploads them when the connection is back.

## Restart, stop, logs

```sh
sudo systemctl restart olvar-gateway
sudo systemctl stop olvar-gateway
journalctl -u olvar-gateway -f
journalctl -u mosquitto -f
```

Logs are capped at 50 MB in total.

## Update to a new release

Push the release's migrations to Supabase **first** (on your computer), then update the Pi:

```sh
cd ~/olvar-gateway
sudo deploy/update.sh <tag>
```

The full order, and the one-time move from `main` to the first tag `v0.1.0`, are in "Updating later" in
DEPLOY.md.

## Change an MQTT password

Never add `-c`: it would erase every other user.

```sh
sudo mosquitto_passwd /etc/mosquitto/passwd <username>
sudo chown mosquitto:mosquitto /etc/mosquitto/passwd
sudo chmod 0600 /etc/mosquitto/passwd
sudo systemctl restart mosquitto
```

For `olvar-gateway`, also update `MQTT_PASSWORD` in `/etc/olvar-gateway/gateway.env` and
`sudo systemctl restart olvar-gateway`. For the ESP32, also enter the new password in its setup.

## Rotate the Supabase secret key

1. Dashboard → **Project Settings → API Keys → Secret keys**: create a new key (for example `gateway-2`).
2. Put it in `SUPABASE_SECRET_KEY` in `/etc/olvar-gateway/gateway.env` and `sudo systemctl restart olvar-gateway`.
3. Check `status` shows `last_error: none`, then delete the old key in the dashboard.

## Replace the ESP32

v1 links exactly one device to the plant. On your computer or in the dashboard's **SQL Editor**, unlink the old one
(this keeps its history):

```sql
update public.devices set plant_id = null where id = '<old-device-id>';
```

Then, on the Pi, run `tools/setup_plant.py` with the new `--device-id` (DEPLOY.md B8), create its MQTT user
(DEPLOY.md B9) and remove the old one:

```sh
sudo mosquitto_passwd -D /etc/mosquitto/passwd <old-device-id>
sudo systemctl restart mosquitto
```

Calibrate the new probe in the app's Soil calibration screen.

## The Pi moved to a different network

The firewall allows MQTT only from the subnet detected at install time. Re-run the installer; it detects the new
subnet (or pass it with `OLVAR_LAN_SUBNET=192.168.1.0/24`):

```sh
cd ~/olvar-gateway
sudo deploy/install.sh
```

## Change the Anthropic key

Create a new key on https://console.anthropic.com (**Settings → API keys → Create key**). Then, on your computer,
in a checkout linked to the project:

```sh
printf 'Anthropic API key: '; read -rs ANTHROPIC_API_KEY; echo
supabase secrets set ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
unset ANTHROPIC_API_KEY
supabase secrets list
```

Answer `y` to the confirmation. Do not redeploy: Supabase gives the running function the new secret without a
deploy, and a deploy would publish whatever code this checkout has. Check a real reply from the running function
(see "Check that chat answers with Claude" below), then disable the old key in the Console.

## Check that chat answers with Claude

The function list showing `chat` as `ACTIVE` is not enough: when the Anthropic call fails, the function still answers
HTTP 200 with a short fallback text. To see a real reply:

1. Send a chat message in the Olvar app and wait for the answer.
2. Supabase dashboard → **SQL Editor**, run:

```sql
select id, created_at, model, error
from public.chat_messages
where role = 'plant'
order by id desc
limit 1;
```

The newest row must show `model` = `claude-sonnet-5-5` (or the model set in `ANTHROPIC_MODEL`) and an empty
`error`. If `error` is set (for example `http 401` for a wrong key, or `timeout`), the reply was the fallback: fix
the cause and check again. The function logs (dashboard → **Edge Functions → chat → Logs**) show an
`anthropic_failed` event with the same error.

## Move the chat from DeepSeek to Claude

For a project that ran the DeepSeek chat. Keep `DEEPSEEK_API_KEY` until the very end, so the old function keeps
working if the deploy fails. On your computer, in the linked checkout, at the release that has the Claude chat:

1. Set the Anthropic key, without touching the DeepSeek one:

   ```sh
   printf 'Anthropic API key: '; read -rs ANTHROPIC_API_KEY; echo
   supabase secrets set ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
   unset ANTHROPIC_API_KEY
   supabase secrets list
   ```

   The list now shows both `ANTHROPIC_API_KEY` and `DEEPSEEK_API_KEY`.
2. Deploy: `supabase functions deploy chat --use-api`, then `supabase functions list` shows `chat` as `ACTIVE`.
3. Check a real Claude reply as in "Check that chat answers with Claude" above. If it fails and cannot be fixed
   quickly, redeploy the previous release's function; it still finds `DEEPSEEK_API_KEY`.
4. Only once a real Claude reply is stored, remove the old secret:

   ```sh
   supabase secrets unset DEEPSEEK_API_KEY
   supabase secrets list
   ```
