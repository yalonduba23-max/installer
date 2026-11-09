#!/usr/bin/env bash
#
# VLESS / VMess / SSH-WebSocket installer behind a Cloudflare Tunnel.
#
#   sudo ./setup.sh               first install (creates a NEW tunnel ws-serverN + its DNS name)
#   sudo ./setup.sh --reinstall   rebuild everything on a server that lost its services (e.g. a restarted container):
#                                 keeps the SAME tunnel (id, name, domain), the SAME UUIDs and the SAME SSH account.
#                                 The identity comes from $STATE_DIR (or the backup in $BACKUP_DIR). If nothing is known
#                                 about a previous install it simply behaves like a first install.
#
# Needs CF_API_TOKEN and CF_ACCOUNT_ID in .env unless SKIP_CLOUDFLARE=true. Optional in .env: SSH_USER / SSH_PASS
# (a fixed SSH proxy account instead of a random makeliNNNNNN one).
#
# The Cloudflare API token (an API *token*, not the global key) needs exactly:
#   Account > Cloudflare Tunnel > Edit        (account resources: the account in CF_ACCOUNT_ID)
#   Zone    > DNS > Edit                      (zone resources: the zone in DEFAULT_ZONE)
#   Zone    > Zone > Read                     (same zone)
# No client-IP filtering (the servers have changing IPs) and preferably no expiry date.

# ----------------------------------------------------------------------------- settings (override with env vars)
STATE_DIR="${STATE_DIR:-/var/lib/vpn-ws-setup}"
LOG="${LOG:-/var/log/vpn-ws-setup.log}"
XRAY_VERSION="${XRAY_VERSION:-v26.10.21}"
XRAY_BIN=/usr/local/bin/xray
XRAY_CONF=/usr/local/etc/xray/config.json
NGINX_SITE=/etc/nginx/sites-enabled/xray.conf
APP_SERVICE=websocket-ssh-proxy
XRAY_SERVICE=xray-ws-proxy
CF_SERVICE=cloudflared-tunnel
CF_BIN="${CF_BIN:-/usr/local/bin/cloudflared}"
CRED_HOME="${CRED_HOME:-/root/makeli-server}"
MANAGER="${MANAGER:-/usr/local/sbin/makeli-manage}"
ETC_CF="${ETC_CF:-/etc/cloudflared}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
# a copy of the identity that survives where the home directory survives (Segfault: /sec/root)
BACKUP_DIR="${BACKUP_DIR:-${HOME:-/root}/.vpn-ws-backup}"
CF_API="${CF_API:-https://api.cloudflare.com/client/v4}"
DEFAULT_ZONE="${DEFAULT_ZONE:-freessh.indevs.in}"
REINSTALL=0

say(){ printf '\n==> %s\n' "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
ask(){ local v; read -r -p "$1" v; printf -v "$2" '%s' "$v"; }

usage(){
  cat <<'USAGE'
Usage: sudo ./setup.sh [--reinstall]
  (no option)   first install: new Cloudflare tunnel, new UUIDs, new SSH account
  --reinstall   rebuild all services and the SAME tunnel / UUIDs / SSH account that this server had before
USAGE
}

# ----------------------------------------------------------------------------- state backup / restore
STATE_FILES=(cloudflare.env uuids.env managed-clients.json)

backup_state(){
  install -d -m 700 "$BACKUP_DIR"
  local f
  for f in "${STATE_FILES[@]}"; do
    if [[ -f "$STATE_DIR/$f" ]]; then install -m 600 "$STATE_DIR/$f" "$BACKUP_DIR/$f"; fi
  done
  if [[ -f "$CRED_HOME/ssh-creds.txt" ]]; then install -m 600 "$CRED_HOME/ssh-creds.txt" "$BACKUP_DIR/ssh-creds.txt"; fi
  return 0
}

restore_state(){
  install -d -m 700 "$STATE_DIR" "$CRED_HOME"
  local f
  for f in "${STATE_FILES[@]}"; do
    if [[ ! -f "$STATE_DIR/$f" && -f "$BACKUP_DIR/$f" ]]; then
      install -m 600 "$BACKUP_DIR/$f" "$STATE_DIR/$f"; echo "restored $f from $BACKUP_DIR"
    fi
  done
  if [[ ! -f "$CRED_HOME/ssh-creds.txt" && -f "$BACKUP_DIR/ssh-creds.txt" ]]; then
    install -m 600 "$BACKUP_DIR/ssh-creds.txt" "$CRED_HOME/ssh-creds.txt"; echo "restored ssh-creds.txt from $BACKUP_DIR"
  fi
  return 0
}

# value of KEY in a KEY=value file (values written by printf %q for ordinary names are not quoted)
env_value(){ sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1 | tr -d "'\""; }

# .env files edited on Windows / pasted from a browser carry \r, spaces or quotes that make the token invalid
clean_env_values(){
  local v
  for v in CF_API_TOKEN CF_ACCOUNT_ID; do
    [[ -n "${!v:-}" ]] && printf -v "$v" '%s' "$(printf '%s' "${!v}" | tr -d '\r\n\t "'"'"'')"
  done
  for v in SSH_USER SSH_PASS; do
    [[ -n "${!v:-}" ]] && printf -v "$v" '%s' "$(printf '%s' "${!v}" | tr -d '\r\n')"
  done
  return 0
}

# ----------------------------------------------------------------------------- Cloudflare helpers (JSON via python3)
# pj 'EXPR'  reads JSON on stdin and prints EXPR evaluated with d = the JSON (empty on any error)
pj(){
  python3 -c '
import sys, json, os
try:
    d = json.load(sys.stdin)
    v = eval(sys.argv[1], {"d": d, "os": os, "len": len, "next": next})
except Exception:
    sys.exit(0)
print("" if v is None else (v if isinstance(v, str) else json.dumps(v)))' "$1"
}

# cf METHOD /path [json-body]  -> response body on stdout (HTTP errors are read from the JSON, not from curl)
cf(){
  local method="$1" path="$2" data="${3:-}"
  local args=(--silent --show-error --max-time 60 -X "$method" -H "Authorization: Bearer $CF_API_TOKEN" -H 'Content-Type: application/json')
  if [[ -n "$data" ]]; then args+=(--data "$data"); fi
  curl "${args[@]}" "$CF_API$path" || true
}

cf_success(){ [[ "$(pj 'd["success"]' <<<"$1")" == true ]]; }
cf_errors(){ pj 'd.get("errors")' <<<"$1" >&2 || true; }

json_obj(){ # json_obj key=value ...   -> {"key":"value",...}
  python3 -c '
import sys, json
print(json.dumps(dict(a.split("=", 1) for a in sys.argv[1:])))' "$@"
}

cf_create_tunnel(){ # $1 = name -> sets TUNNEL_ID; returns 1 (and sets CF_LAST) on failure
  local secret payload created
  secret="$(openssl rand -base64 32 | tr -d '\n')"
  payload="$(python3 -c '
import sys, json
print(json.dumps({"name": sys.argv[1], "tunnel_secret": sys.argv[2], "config_src": "cloudflare"}))' "$1" "$secret")"
  created="$(cf POST "/accounts/$CF_ACCOUNT_ID/cfd_tunnel" "$payload")"
  if ! cf_success "$created"; then CF_LAST="$created"; return 1; fi
  TUNNEL_ID="$(pj 'd["result"]["id"]' <<<"$created")"
  [[ -n "$TUNNEL_ID" ]] || { CF_LAST="$created"; return 1; }
  return 0
}

cf_ensure_dns(){ # $1 hostname, $2 CNAME target
  local r count id cur payload
  payload="$(python3 -c '
import sys, json
print(json.dumps({"type": "CNAME", "name": sys.argv[1], "content": sys.argv[2], "proxied": True, "ttl": 1}))' "$1" "$2")"
  r="$(cf GET "/zones/$ZONE_ID/dns_records?name=$1")"
  cf_success "$r" || { cf_errors "$r"; die "DNS lookup for $1 failed."; }
  count="$(pj 'len(d["result"])' <<<"$r")"
  if [[ "$count" == 0 ]]; then
    r="$(cf POST "/zones/$ZONE_ID/dns_records" "$payload")"
    cf_success "$r" || { cf_errors "$r"; die "DNS creation failed for $1."; }
    echo "DNS: created $1 -> $2"
  else
    id="$(pj 'd["result"][0]["id"]' <<<"$r")"
    cur="$(pj 'd["result"][0]["content"]' <<<"$r")"
    if [[ "$cur" == "$2" ]]; then
      echo "DNS: $1 already points to the tunnel"
    else
      r="$(cf PUT "/zones/$ZONE_ID/dns_records/$id" "$payload")"
      cf_success "$r" || { cf_errors "$r"; die "DNS update failed for $1."; }
      echo "DNS: re-pointed $1 -> $2"
    fi
  fi
}

write_cf_state(){
  install -d -m 700 "$STATE_DIR"
  printf 'TUNNEL_NAME=%q\nTUNNEL_ID=%q\nHOSTNAME=%q\n' "$TUNNEL_NAME" "$TUNNEL_ID" "$HOSTNAME" > "$STATE_DIR/cloudflare.env"
  chmod 600 "$STATE_DIR/cloudflare.env"
  install -d -m 700 "$BACKUP_DIR"
  install -m 600 "$STATE_DIR/cloudflare.env" "$BACKUP_DIR/cloudflare.env"
}

# Stops early, with a clear reason, when the token is wrong / expired / missing a permission.
cf_preflight(){
  local r st
  r="$(cf GET "/user/tokens/verify")"
  if ! cf_success "$r"; then r="$(cf GET "/accounts/$CF_ACCOUNT_ID/tokens/verify")"; fi   # account-owned tokens
  if ! cf_success "$r"; then
    cf_errors "$r"
    die "Cloudflare rejected CF_API_TOKEN: check .env (no quotes/spaces, an API token not the global key, not deleted)."
  fi
  st="$(pj 'd["result"].get("status", "")' <<<"$r")"
  [[ "$st" == active ]] || die "The Cloudflare API token is not active (status: ${st:-unknown}); create a new one."
  r="$(cf GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel?per_page=1&is_deleted=false")"
  cf_success "$r" || { cf_errors "$r"; die "The token cannot reach the tunnels of account $CF_ACCOUNT_ID: it needs Account > Cloudflare Tunnel > Edit, and CF_ACCOUNT_ID must be that account."; }
  echo "Cloudflare token OK (active, tunnels reachable)"
}

# Creates (first install) or re-attaches (--reinstall) the remotely-managed tunnel and starts cloudflared.
setup_cloudflare(){
  CF_API_TOKEN="${CF_API_TOKEN:-}"
  CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-}"
  clean_env_values
  [[ -n "$CF_API_TOKEN" && -n "$CF_ACCOUNT_ID" ]] || die "Set CF_API_TOKEN and CF_ACCOUNT_ID in .env; setup runs non-interactively."
  cf_preflight

  local zones r tunnels num exists dns_check prev_id="" prev_name="" prev_host="" token_result TUNNEL_TOKEN ingress ZONE_NAME

  zones="$(cf GET "/zones?per_page=50")"
  cf_success "$zones" || { cf_errors "$zones"; die "Could not list zones; check the API token."; }
  ZONE_NAME="$DEFAULT_ZONE"
  ZONE_ID="$(Z="$ZONE_NAME" pj 'next((z["id"] for z in d["result"] if z["name"] == os.environ["Z"]), "")' <<<"$zones")"
  if [[ -z "$ZONE_ID" ]]; then
    echo "The default zone '$ZONE_NAME' was not found in the zones accessible to this API token."
    echo "Available zones:"; pj '"\n".join(" - " + z["name"] for z in d["result"])' <<<"$zones"
    die "Make sure the token can access '$ZONE_NAME' and has Zone:Read and DNS:Edit permissions."
  fi
  echo "Using Cloudflare zone: $ZONE_NAME"

  TUNNEL_ID=""
  if (( REINSTALL )) && [[ -f "$STATE_DIR/cloudflare.env" ]]; then
    prev_id="$(env_value "$STATE_DIR/cloudflare.env" TUNNEL_ID)"
    prev_name="$(env_value "$STATE_DIR/cloudflare.env" TUNNEL_NAME)"
    prev_host="$(env_value "$STATE_DIR/cloudflare.env" HOSTNAME)"
  fi

  if [[ -n "$prev_id" && -n "$prev_host" ]]; then
    echo "Reinstall: this server had tunnel $prev_name ($prev_id) for $prev_host"
    r="$(cf GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$prev_id")"
    if cf_success "$r" && [[ -z "$(pj 'd["result"].get("deleted_at") or ""' <<<"$r")" ]]; then
      TUNNEL_ID="$prev_id"; TUNNEL_NAME="${prev_name:-ws-server}"; HOSTNAME="$prev_host"
      echo "Reusing the existing Cloudflare tunnel (same id, same domain)."
    else
      echo "The old tunnel no longer exists in Cloudflare: creating a new tunnel with the SAME name and domain."
      TUNNEL_NAME="${prev_name:-ws-server}"; HOSTNAME="$prev_host"
      if ! cf_create_tunnel "$TUNNEL_NAME"; then cf_errors "${CF_LAST:-}"; die "Tunnel create failed."; fi
    fi
  else
    (( REINSTALL )) && echo "No previous tunnel known for this server: creating a new one."
    # first unused ws-serverN (checked against Cloudflare itself); retried if another server takes the name meanwhile
    local tries=0
    num=1
    while :; do
      tunnels="$(cf GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel?per_page=100&is_deleted=false")"
      cf_success "$tunnels" || { cf_errors "$tunnels"; die "Tunnel listing failed."; }
      TUNNEL_NAME="ws-server${num}"
      HOSTNAME="ws-server${num}.${ZONE_NAME}"
      exists="$(N="$TUNNEL_NAME" pj 'len([t for t in d["result"] if t["name"] == os.environ["N"]])' <<<"$tunnels")"
      dns_check="$(cf GET "/zones/$ZONE_ID/dns_records?name=$HOSTNAME")"
      cf_success "$dns_check" || { cf_errors "$dns_check"; die "DNS lookup failed."; }
      if [[ "$exists" == 0 && "$(pj 'len(d["result"])' <<<"$dns_check")" == 0 ]]; then
        echo "Automatically selected tunnel: $TUNNEL_NAME"
        echo "Automatically selected hostname: $HOSTNAME"
        if cf_create_tunnel "$TUNNEL_NAME"; then break; fi
        # only a name clash (code 1013) is worth retrying with the next number; anything else is a real error
        if ! grep -q '"code": *1013' <<<"${CF_LAST:-}"; then
          cf_errors "${CF_LAST:-}"
          die "Tunnel create failed (not a name clash): the token needs Account > Cloudflare Tunnel > Edit for account $CF_ACCOUNT_ID."
        fi
        tries=$((tries + 1))
        (( tries < 12 )) || { cf_errors "${CF_LAST:-}"; die "Tunnel create failed after $tries tries."; }
        echo "Name $TUNNEL_NAME was taken meanwhile; trying the next one."
      fi
      num=$((num + 1))
    done
  fi

  write_cf_state                                   # identity saved at once: a later failure still leaves it for --reinstall

  token_result="$(cf GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/token")"
  cf_success "$token_result" || { cf_errors "$token_result"; die "Tunnel token retrieval failed."; }
  TUNNEL_TOKEN="$(pj 'd["result"]' <<<"$token_result")"
  [[ -n "$TUNNEL_TOKEN" && "$TUNNEL_TOKEN" != null ]] || die "Empty tunnel token."

  install -d -m 700 "$ETC_CF"
  printf 'TUNNEL_TOKEN=%s\n' "$TUNNEL_TOKEN" > "$ETC_CF/tunnel-token.env"
  chmod 600 "$ETC_CF/tunnel-token.env"

  cf_ensure_dns "$HOSTNAME" "$TUNNEL_ID.cfargotunnel.com"

  ingress="$(python3 -c '
import sys, json
print(json.dumps({"config": {"ingress": [{"hostname": sys.argv[1], "service": "http://127.0.0.1:80"}, {"service": "http_status:404"}]}}))' "$HOSTNAME")"
  r="$(cf PUT "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" "$ingress")"
  cf_success "$r" || { cf_errors "$r"; die "Tunnel ingress update failed."; }

  if [[ ! -x "$CF_BIN" ]]; then
    local arch cfarch
    arch="$(dpkg --print-architecture)"
    case "$arch" in amd64) cfarch=amd64;; arm64) cfarch=arm64;; armhf) cfarch=arm;; *) die "Unsupported architecture: $arch";; esac
    curl --fail --location --retry 3 --retry-all-errors "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cfarch}" -o "$CF_BIN"
    chmod 755 "$CF_BIN"
  fi

  cat > "$SYSTEMD_DIR/${CF_SERVICE}.service" <<EOF
[Unit]
Description=Cloudflare Tunnel $TUNNEL_NAME
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=$ETC_CF/tunnel-token.env
ExecStart=$CF_BIN tunnel run --token \${TUNNEL_TOKEN}
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$CF_SERVICE"
  if (( REINSTALL )); then systemctl restart "$CF_SERVICE"; fi
  echo "Cloudflare tunnel $TUNNEL_NAME ($TUNNEL_ID) is running for https://$HOSTNAME"
  unset CF_API_TOKEN TUNNEL_TOKEN
}

# Rebuilds the xray client list from managed-clients.json (the labelled UUIDs with expiry the server had before).
apply_managed_clients(){
  [[ -f "$STATE_DIR/managed-clients.json" && -x "$MANAGER" ]] || return 0
  python3 - "$MANAGER" <<'PY' || echo "WARNING: could not re-apply the managed clients (run: makeli-manage, option 6)"
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("makeli_manage", sys.argv[1])
spec = importlib.util.spec_from_loader("makeli_manage", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod.apply(mod.load())
print("managed VLESS/VMess clients re-applied to xray")
PY
}

# ----------------------------------------------------------------------------- tests can stop here and use the functions
if [[ "${SETUP_SOURCE_ONLY:-0}" == 1 ]]; then return 0 2>/dev/null || exit 0; fi

set -Eeuo pipefail
umask 077
for arg in "$@"; do
  case "$arg" in
    --reinstall) REINSTALL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$HERE/.env}"
APP="$HERE/w3bs0cket.py"
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
touch "$LOG"; chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
done_step(){ grep -qxF "$1" "$STATE_DIR/state" 2>/dev/null; }
mark_step(){ touch "$STATE_DIR/state"; grep -qxF "$1" "$STATE_DIR/state" || echo "$1" >> "$STATE_DIR/state"; }
[[ $EUID -eq 0 ]] || die "Run: sudo bash setup.sh"
[[ -f "$APP" ]] || die "Place w3bs0cket.py beside setup.sh."
command -v systemctl >/dev/null || die "systemd is required."
# .env is a trusted local file; never commit it.
if [[ -f "$ENV_FILE" ]]; then set -a; source "$ENV_FILE"; set +a; fi
clean_env_values
export NOCOLOR="${NOCOLOR:-0}" TOR="${TOR:-}"
if (( REINSTALL )); then
  say "REINSTALL: restoring the identity (tunnel, UUIDs, SSH account) this server had before"
  restore_state
  # packages lost with a restarted container: run the dependency step again
  for c in nginx python3 curl unzip jq ss openssl sshd; do
    if ! command -v "$c" >/dev/null 2>&1; then sed -i '/^deps$/d' "$STATE_DIR/state" 2>/dev/null || true; break; fi
  done
fi

say "Fixing known Kali shellrc nounset hazards (with backup)"
for rc in /etc/shellrc /etc/bash.bashrc /root/.bashrc; do
[[ -f "$rc" ]] || continue
if grep -qE '\$NOCOLOR|\[\[ -n \$1 \]\]|\[\[ "\$[12]" ==' "$rc"; then
cp -an "$rc" "${rc}.vpn-setup.bak" 2>/dev/null || true
sed -i -e 's/"\$NOCOLOR"/"${NOCOLOR:-}"/g' \
-e 's/\[\[ -n \$1 \]\]/[[ -n ${1:-} ]]/g' \
-e 's/\[\[ "\$1" ==/[[ "${1:-}" ==/g' \
-e 's/\[\[ "\$2" ==/[[ "${2:-}" ==/g' "$rc"
fi
done
apt_recover(){
local n=1
while (( n <= 3 )); do
apt-get update && return 0
apt-get update --fix-missing && return 0
n=$((n+1)); sleep 2
done
die "APT update failed after 3 attempts; fix network/repositories and rerun."
}
if ! done_step deps; then

say "Installing dependencies"
export DEBIAN_FRONTEND=noninteractive
apt_recover
if ! apt-get install -y --fix-missing ca-certificates curl unzip nginx python3 python3-pip python3-venv jq iproute2 openssh-server; then
apt-get update --fix-missing || true
apt-get install -y --fix-missing ca-certificates curl unzip nginx python3 python3-pip python3-venv jq iproute2 openssh-server \
|| die "APT install failed. Fix repositories/network and rerun setup.sh."
fi
mark_step deps
fi

say "Starting SSH and creating a restricted SSH-proxy account"
install -d -m 700 "$CRED_HOME"
# --reinstall keeps the SSH account the server had (the credentials file is restored above)
if (( REINSTALL )) && [[ -z "${SSH_USER:-}" && -f "$CRED_HOME/ssh-creds.txt" ]]; then
  SSH_USER="$(env_value "$CRED_HOME/ssh-creds.txt" SSH_USER)"
  SSH_PASS="$(env_value "$CRED_HOME/ssh-creds.txt" SSH_PASS)"
fi
SSH_USER="${SSH_USER:-makeli$(od -An -N3 -tu4 /dev/urandom | tr -d ' ')}"
SSH_PASS="${SSH_PASS:-$(openssl rand -hex 10)}"
if (( ${#SSH_PASS} < 10 )); then echo "WARNING: SSH_PASS is shorter than 10 characters; this account is reachable from the internet."; fi
if ! id "$SSH_USER" >/dev/null 2>&1; then useradd -m -d "/home/$SSH_USER" -s /usr/sbin/nologin "$SSH_USER"; fi
printf '%s:%s\n' "$SSH_USER" "$SSH_PASS" | chpasswd
passwd -u "$SSH_USER" >/dev/null 2>&1 || true
# written now (not only at the end) so a failure further down still leaves the identity for --reinstall
printf 'SSH_USER=%s\nSSH_PASS=%s\n' "$SSH_USER" "$SSH_PASS" > "$CRED_HOME/ssh-creds.txt"
chmod 600 "$CRED_HOME/ssh-creds.txt"
systemctl enable ssh
service ssh start

say "Installing Xray"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl --fail --location --retry 3 --retry-all-errors "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip" -o "$tmp/xray.zip"
mkdir "$tmp/unpack"; unzip -oq "$tmp/xray.zip" -d "$tmp/unpack"
install -m 755 "$tmp/unpack/xray" "$XRAY_BIN"
install -d /usr/local/share/xray
for f in geoip.dat geosite.dat; do [[ ! -f "$tmp/unpack/$f" ]] || install -m 644 "$tmp/unpack/$f" "/usr/local/share/xray/$f"; done
rm -rf "$tmp"; trap - EXIT
UUID_FILE="$STATE_DIR/uuids.env"
if [[ -f "$UUID_FILE" ]]; then source "$UUID_FILE"; else
VLESS_UUID="$("$XRAY_BIN" uuid)"; VMESS_UUID="$("$XRAY_BIN" uuid)"
printf 'VLESS_UUID=%q\nVMESS_UUID=%q\n' "$VLESS_UUID" "$VMESS_UUID" > "$UUID_FILE"; chmod 600 "$UUID_FILE"
fi
install -d -m 700 "$CRED_HOME"
printf 'VLESS_UUID=%s\nVMESS_UUID=%s\n' "$VLESS_UUID" "$VMESS_UUID" > "$CRED_HOME/protocol-creds.txt"
chmod 600 "$CRED_HOME/protocol-creds.txt"
backup_state
install -d /usr/local/etc/xray
[[ ! -f "$XRAY_CONF" || -f "${XRAY_CONF}.vpn-setup.bak" ]] || cp -a "$XRAY_CONF" "${XRAY_CONF}.vpn-setup.bak"
cat > "$XRAY_CONF" <<EOF
{
"log":{"loglevel":"warning"},
"inbounds":[
{"listen":"127.0.0.1","port":10001,"protocol":"vless","settings":{"clients":[{"id":"$VLESS_UUID"}],"decryption":"none"},"streamSettings":{"network":"ws","wsSettings":{"path":"/vless"}}},
{"listen":"127.0.0.1","port":10002,"protocol":"vmess","settings":{"clients":[{"id":"$VMESS_UUID"}]},"streamSettings":{"network":"ws","wsSettings":{"path":"/vmess"}}}
],
"outbounds":[{"protocol":"freedom"},{"protocol":"blackhole","tag":"block"}]
}
EOF
"$XRAY_BIN" run -test -c "$XRAY_CONF"
cat > "$SYSTEMD_DIR/${XRAY_SERVICE}.service" <<EOF
[Unit]
Description=Xray VLESS/VMess WebSocket
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=$XRAY_BIN run -config $XRAY_CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF

say "Configuring Nginx"
install -d /etc/nginx/sites-enabled
[[ ! -f "$NGINX_SITE" || -f "${NGINX_SITE}.vpn-setup.bak" ]] || cp -a "$NGINX_SITE" "${NGINX_SITE}.vpn-setup.bak"
rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default
cat > "$NGINX_SITE" <<'EOF'
map $http_upgrade $connection_upgrade {
default upgrade;
'' close;
}
server {
listen 80;
listen [::]:80;
server_name _;
location = /vless {
proxy_pass http://127.0.0.1:10001;
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
proxy_set_header Host $host;
proxy_read_timeout 86400s;
proxy_buffering off;
}
location = /vmess {
proxy_pass http://127.0.0.1:10002;
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
proxy_set_header Host $host;
proxy_read_timeout 86400s;
proxy_buffering off;
}
location / {
proxy_pass http://127.0.0.1:8080;
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
proxy_set_header Host $host;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_read_timeout 86400s;
proxy_buffering off;
}
}
EOF
nginx -t

say "Installing Makeli Servers SSH banner"
cat > "$HERE/ssh_banner" <<'BANNER'
<h6><font color="#ff3333">MAKELI SERVERS</font></h6>
<font color="#1a9fff">FAST • SECURE • RELIABLE</font><br><br>
<font color="#00ff66">╔════════ INTERNET FREEDOM ════════╗</font><br>
<font color="#ff3333">WARNING — USE THIS SERVER LEGALLY</font><br>
<font color="#ff3333">NO HACKING</font><br>
<font color="#ff3333">NO CARDING</font><br>
<font color="#ff3333">NO DDOS ATTACKING</font><br>
<font color="#ff3333">NO SPAMMING</font><br>
<font color="#ff3333">NO TORRENTING</font><br>
<font color="#ff3333">NO MULTILOGINS</font><br><br>
<font color="#1a9fff">Telegram: https://t.me/+fn-DT14YZe5kZTg0</font><br>
<font color="#1a9fff">MAKELI SERVERS • FAST • SECURE • RELIABLE</font>
BANNER
chmod 644 "$HERE/ssh_banner"

say "Installing Makeli account and expiry manager"
cat > "$MANAGER" <<'MANAGER'
#!/usr/bin/env python3
import datetime, json, os, pwd, secrets, string, subprocess, sys, uuid
from pathlib import Path
STATE=Path('/var/lib/vpn-ws-setup')
CLIENTS=STATE/'managed-clients.json'
CONF=Path('/usr/local/etc/xray/config.json')
CRED=Path('/root/makeli-server')
def run(*args, check=True): return subprocess.run(args, check=check, text=True, capture_output=True)
def load():
    if CLIENTS.exists(): return json.loads(CLIENTS.read_text())
    data={'vless': [], 'vmess': []}
    for proto, key in [('vless','VLESS_UUID'),('vmess','VMESS_UUID')]:
        f=STATE/'uuids.env'
        val=''
        if f.exists():
            for line in f.read_text().splitlines():
                if line.startswith(key+'='): val=line.split('=',1)[1].strip().strip("'\"")
        if val: data[proto].append({'name':'default','uuid':val,'expires':None})
    save(data); return data
def save(data):
    CLIENTS.write_text(json.dumps(data,indent=2)+'\n'); os.chmod(CLIENTS,0o600)
    CRED.mkdir(mode=0o700, parents=True, exist_ok=True)
    for proto in ('vless','vmess'):
        lines=[f"{c['name']}\t{c['uuid']}\texpires={c.get('expires') or 'never'}" for c in data[proto]]
        target=CRED/f'{proto}-clients.txt'; target.write_text('\n'.join(lines)+'\n'); os.chmod(target,0o600)
def apply(data):
    conf=json.loads(CONF.read_text())
    for inbound in conf.get('inbounds',[]):
        proto=inbound.get('protocol')
        if proto=='vless': inbound.setdefault('settings',{})['clients']=[{'id':c['uuid'],'email':c['name']} for c in data['vless']]
        elif proto=='vmess': inbound.setdefault('settings',{})['clients']=[{'id':c['uuid'],'email':c['name']} for c in data['vmess']]
    tmp=CONF.with_suffix('.json.tmp'); tmp.write_text(json.dumps(conf,indent=2)+'\n'); os.chmod(tmp,0o600); tmp.replace(CONF)
    run('/usr/local/bin/xray','run','-test','-c',str(CONF)); run('systemctl','restart','xray-ws-proxy')
def expiry_date(days): return (datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=days)).isoformat()
def add_ssh():
    name=input('SSH username: ').strip()
    if not name or not name.replace('_','').replace('-','').isalnum() or name[0].isdigit(): print('Invalid username'); return
    if subprocess.run(['id',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0: print('User already exists'); return
    password=''.join(secrets.choice(string.ascii_letters+string.digits+'!@#%_+-') for _ in range(18))
    run('useradd','-m','-s','/usr/sbin/nologin',name); subprocess.run(['chpasswd'],input=f'{name}:{password}\n',text=True,check=True)
    print(f'Created SSH proxy account: {name}\nPassword: {password}\nShell: /usr/sbin/nologin (no interactive shell)')
def remove_ssh():
    name=input('SSH username to remove: ').strip()
    if name in ('root','daemon','nobody','www-data'): print('Refusing to remove a system account'); return
    try: pwd.getpwnam(name)
    except KeyError: print('User not found'); return
    if input(f'Delete {name} and its home directory? [yes/NO] ').strip()!='yes': print('Cancelled'); return
    run('userdel','-r',name,check=False); print('Removed',name)
def add_client(data):
    proto=input('Protocol [vless/vmess]: ').strip().lower()
    if proto not in ('vless','vmess'): print('Invalid protocol'); return
    name=input('Client label: ').strip()
    if not name or any(c['name']==name for c in data[proto]): print('Label missing or already used for this protocol'); return
    try: days=int(input('Expiry in days (0 = never): ').strip())
    except ValueError: print('Enter a number'); return
    if days<0: print('Days must be 0 or greater'); return
    data[proto].append({'name':name,'uuid':str(uuid.uuid4()),'expires':expiry_date(days) if days else None})
    save(data); apply(data)
    print(f'{proto.upper()} client: {name}\nUUID: {data[proto][-1]["uuid"]}\nExpiry: {data[proto][-1]["expires"] or "never"}')
def remove_client(data):
    proto=input('Protocol [vless/vmess]: ').strip().lower()
    if proto not in ('vless','vmess'): print('Invalid protocol'); return
    for i,c in enumerate(data[proto]): print(f'{i+1}. {c["name"]} | {c["uuid"]} | expires={c["expires"] or "never"}')
    name=input('Label to remove: ').strip(); new=[c for c in data[proto] if c['name']!=name]
    if len(new)==len(data[proto]): print('Label not found'); return
    data[proto]=new; save(data); apply(data); print('Removed',name)
def list_all(data):
    for proto in ('vless','vmess'):
        print('\n'+proto.upper())
        for c in data[proto]: print(f' {c["name"]}: {c["uuid"]} | expires={c["expires"] or "never"}')
def expire():
    data=load(); now=datetime.datetime.now(datetime.timezone.utc); changed=False
    for proto in ('vless','vmess'):
        kept=[]
        for c in data[proto]:
            if c.get('expires'):
                try: exp=datetime.datetime.fromisoformat(c['expires'])
                except ValueError: kept.append(c); continue
                if exp.tzinfo is None: exp=exp.replace(tzinfo=datetime.timezone.utc)
                if exp<=now: print(f'Expired {proto} client: {c["name"]}'); changed=True; continue
            kept.append(c)
        data[proto]=kept
    if changed: save(data); apply(data)
def main():
    if os.geteuid()!=0: sys.exit('Run as root: sudo makeli-manage')
    if len(sys.argv)>1 and sys.argv[1]=='expire': expire(); return
    while True:
        print('\n=== MAKELI SERVERS MANAGER ===\n1) Add SSH proxy user (no shell)\n2) Remove SSH user\n3) Add VLESS/VMess client with expiry\n4) Remove VLESS/VMess client\n5) List protocol clients\n6) Run expiry cleanup now\n0) Exit')
        choice=input('Select: ').strip(); data=load()
        try:
            if choice=='1': add_ssh()
            elif choice=='2': remove_ssh()
            elif choice=='3': add_client(data)
            elif choice=='4': remove_client(data)
            elif choice=='5': list_all(data)
            elif choice=='6': expire()
            elif choice=='0': break
            else: print('Invalid choice')
        except (subprocess.CalledProcessError, OSError) as e: print('Operation failed:',e)
if __name__=='__main__': main()
MANAGER
chmod 750 "$MANAGER"

say "Creating systemd services"
cat > "$SYSTEMD_DIR/${APP_SERVICE}.service" <<EOF
[Unit]
Description=WebSocket SSH proxy
After=network-online.target
Wants=network-online.target
[Service]
WorkingDirectory=$HERE
ExecStart=/usr/bin/python3 $APP
Restart=on-failure
RestartSec=3
User=root
Environment=PYTHONUNBUFFERED=1
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now "$XRAY_SERVICE" "$APP_SERVICE" nginx
# a service that is already running keeps its old config: restart so a reinstall really applies everything
if (( REINSTALL )); then systemctl restart "$XRAY_SERVICE" "$APP_SERVICE" nginx; fi
service ssh start

say "Waiting for w3bs0cket.py on port 8080 before testing"
ready=0
for _ in $(seq 1 30); do
if ss -ltnH 'sport = :8080' | grep -q .; then ready=1; break; fi
systemctl is-active --quiet "$APP_SERVICE" || break
sleep 1
done
if [[ $ready -ne 1 ]]; then
systemctl --no-pager --full status "$APP_SERVICE" || true
journalctl -u "$APP_SERVICE" -n 60 --no-pager || true
die "Python service did not listen on port 8080. Fix dependencies/startup and rerun."
fi
systemctl restart nginx

say "Cloudflare remotely-managed Tunnel setup (no browser URL login)"
if [[ "${SKIP_CLOUDFLARE:-false}" != true ]]; then
setup_cloudflare
else
echo "Skipping Cloudflare because SKIP_CLOUDFLARE=true"
fi
# Seed the managed-client database with the installer-created UUIDs.
if [[ ! -f /var/lib/vpn-ws-setup/managed-clients.json ]]; then
jq -n --arg vu "$VLESS_UUID" --arg mu "$VMESS_UUID" '{vless:[{name:"default",uuid:$vu,expires:null}],vmess:[{name:"default",uuid:$mu,expires:null}]}' > /var/lib/vpn-ws-setup/managed-clients.json
chmod 600 /var/lib/vpn-ws-setup/managed-clients.json
fi
# --reinstall: put the labelled clients (with their expiry) back into the xray config
if (( REINSTALL )); then apply_managed_clients; fi
cat > "$SYSTEMD_DIR/makeli-expiry.service" <<EOF
[Unit]
Description=Expire Makeli VLESS/VMess clients
[Service]
Type=oneshot
ExecStart=$MANAGER expire
EOF
cat > "$SYSTEMD_DIR/makeli-expiry.timer" <<'EOF'
[Unit]
Description=Daily expiry check for Makeli clients
[Timer]
OnBootSec=2min
OnUnitActiveSec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now makeli-expiry.timer || echo "WARNING: expiry timer not available here (no real systemd): run 'makeli-manage expire' from the panel instead"
printf 'SSH_USER=%s\nSSH_PASS=%s\n' "$SSH_USER" "$SSH_PASS" > "$CRED_HOME/ssh-creds.txt"
chmod 600 "$CRED_HOME/ssh-creds.txt"
# keep a copy of the identity where the home directory survives a container restart
backup_state

say "Final status"
systemctl --no-pager --full status "$XRAY_SERVICE" "$APP_SERVICE" nginx ssh || true
[[ "${SKIP_CLOUDFLARE:-false}" == true ]] || systemctl --no-pager --full status "$CF_SERVICE" || true
echo "VLESS UUID: $VLESS_UUID"
echo "VMess UUID: $VMESS_UUID"
echo "SSH proxy account: $SSH_USER"
echo "SSH proxy password: $SSH_PASS"
echo "Credentials saved privately under: $CRED_HOME (mode 700; files mode 600)"
echo "Management menu: sudo makeli-manage"
echo "SSH accounts use /usr/sbin/nologin; they do not receive an interactive shell."
if [[ -f "$STATE_DIR/cloudflare.env" ]]; then source "$STATE_DIR/cloudflare.env"; echo "Tunnel: $TUNNEL_NAME ($TUNNEL_ID)"; echo "URL: https://$HOSTNAME"; fi
echo "Logs: $LOG and journalctl -u $APP_SERVICE -f"
if (( REINSTALL )); then echo "REINSTALL COMPLETE"; fi
