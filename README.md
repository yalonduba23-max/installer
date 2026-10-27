# WebSocket VPN / SSH + Cloudflare Tunnel setup

Put `setup.sh` and your existing `w3bs0cket.py` in the same directory.

## Cloudflare API authentication without browser URL
Yes. Use a scoped Cloudflare API token and Account ID. This script uses Cloudflare's API to create a remotely managed tunnel and retrieve its run token; it does not need `cloudflared tunnel login`. Create a token with:
- Account: Cloudflare Tunnel — Edit
- Zone: Zone — Read
- Zone: DNS — Edit

Keep the token scoped to the required account/zone. Do not use the Global API Key.

## Configure and run
```bash
cp .env.example .env
chmod 600 .env
nano .env
chmod +x setup.sh
sudo bash setup.sh
```
The script prompts you to choose an accessible zone, sequential/random tunnel naming, and a subdomain label. It stores the API token in `.env` if you choose to enter it there; the tunnel run token is stored root-only in `/etc/cloudflared/tunnel-token.env`.

## Private GitHub repository
Create an empty **private** repository on GitHub, then:
```bash
git init
git add setup.sh .env.example .gitignore README.md w3bs0cket.py
git commit -m "Add automated VPN tunnel setup"
git branch -M main
git remote add origin git@github.com:YOUR_ACCOUNT/YOUR_PRIVATE_REPO.git
git push -u origin main
```
Never run `git add .env`. Verify with `git check-ignore .env`. A private repo is not a secrets vault: every collaborator can read committed secrets, and secrets remain in Git history. If a token is ever committed, revoke it and create another.

## Services and credentials
- `service ssh start` is run and SSH is enabled at boot.
- User `andreas` is created and its password is set to `andreas` as requested. This is dangerously weak for a network-accessible machine; change it immediately using `passwd andreas`.
- Separate VLESS and VMess UUIDs are generated and persisted at `/var/lib/vpn-ws-setup/uuids.env`.
- APT retries normal update and `apt-get update --fix-missing`, then offers retry/continue/quit if it remains broken.
- Setup state and log are in `/var/lib/vpn-ws-setup/state` and `/var/log/vpn-ws-setup.log`.
- The Python service is started and must bind port 8080 before the final checks.
- Nginx routes `/vless` to Xray port 10001, `/vmess` to port 10002, and other requests to port 8080.

Review the script before running on a production host. Cloudflare API endpoint/permission behavior can change; check the API response if tunnel creation fails.
