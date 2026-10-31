## Whate The Tool Does
It installs a cloudflare tunnel and installs ssh-websocket vless and vmess vpn setup for use for vpn connection accross cloudflare Network Domains.

# NOTE TO ONLY CONFIGURE YOUR REAL API KEYS ONCE YOU HAVE CLONED THE REPOSITORY IN YOUR LOCAL OR REMOTE PC .env FILE

## Prepare your API KEYS
 This script uses Cloudflare's API to create a remotely managed tunnel and retrieve its run token.
- Account: Cloudflare Tunnel — Edit
- Zone: Zone — Read
- Zone: DNS — Edit

+=>Keep the token scoped to the required account/zone. Do not use the Global API Key.

## Configure and replace with your API KEYS
```bash
cp .env.example .env
chmod 600 .env
nano .env
chmod +x setup.sh
sudo ./setup.sh
```

## Services and credentials
- `service ssh start` is run and SSH is enabled at boot on port 22.
- User `user` is created and its password is set to `user` as requested.
- Separate VLESS and VMess UUIDs are generated and persisted at `/var/lib/vpn-ws-setup/uuids.env`.
- APT retries normal update and `apt-get update --fix-missing`,
- Setup state and log are in `/var/lib/vpn-ws-setup/state` and `/var/log/vpn-ws-setup.log`.
- The Python service is started and must bind port 8080 before the final checks.
- Nginx routes `/vless` to Xray port 10001, `/vmess` to port 10002, and other requests to port 8080.

Review the script before running on a production host. Cloudflare API endpoint/permission behavior can change; check the API response if tunnel creation fails.
