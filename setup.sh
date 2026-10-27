#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$HERE/.env}"
STATE_DIR=/var/lib/vpn-ws-setup
LOG=/var/log/vpn-ws-setup.log
XRAY_VERSION="${XRAY_VERSION:-v26.10.21}"
XRAY_BIN=/usr/local/bin/xray
XRAY_CONF=/usr/local/etc/xray/config.json
NGINX_SITE=/etc/nginx/sites-enabled/xray.conf
APP="$HERE/w3bs0cket.py"
APP_SERVICE=websocket-ssh-proxy
XRAY_SERVICE=xray-ws-proxy
CF_SERVICE=cloudflared-tunnel
CF_BIN=/usr/local/bin/cloudflared
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
touch "$LOG"; chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1

say(){ printf '\n==> %s\n' "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
ask(){ local v; read -r -p "$1" v; printf -v "$2" '%s' "$v"; }
done_step(){ grep -qxF "$1" "$STATE_DIR/state" 2>/dev/null; }
mark_step(){ touch "$STATE_DIR/state"; grep -qxF "$1" "$STATE_DIR/state" || echo "$1" >> "$STATE_DIR/state"; }
[[ $EUID -eq 0 ]] || die "Run: sudo bash setup.sh"
[[ -f "$APP" ]] || die "Place w3bs0cket.py beside setup.sh."
command -v systemctl >/dev/null || die "systemd is required."

# .env is a trusted local file; never commit it.
if [[ -f "$ENV_FILE" ]]; then set -a; source "$ENV_FILE"; set +a; fi
export NOCOLOR="${NOCOLOR:-0}" TOR="${TOR:-}"

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
  local n=1 choice
  while (( n <= 3 )); do
    if apt-get update && return 0; then :; fi
    echo "apt-get update failed; trying --fix-missing"
    if apt-get update --fix-missing; then return 0; fi
    n=$((n+1)); sleep 2
  done
  while true; do
    read -r -p "APT still failing: [r]etry fix-missing, [c]ontinue to install attempt, [q]uit and rerun later: " choice
    case "$choice" in
      r) apt-get update --fix-missing && return 0 ;;
      c) return 0 ;;
      q) die "Stopped. Fix APT/network and rerun setup.sh; progress is recorded." ;;
    esac
  done
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

say "Starting SSH and creating requested Linux account"
id andreas >/dev/null 2>&1 || useradd -m -s /bin/bash andreas
printf '%s:%s\n' andreas andreas | chpasswd
usermod -aG sudo andreas || true
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

cat > "/etc/systemd/system/${XRAY_SERVICE}.service" <<EOF
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

say "Creating systemd services"
cat > "/etc/systemd/system/${APP_SERVICE}.service" <<EOF
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
  CF_API_TOKEN="cfut_Goaax5sua3gD6TClmd0xiiXpmAyPs7OcQLPxWeFA5d4a8785:-"
  CF_ACCOUNT_ID="eb8c55ccb538d4ce94b0083e4eabcab9:-"
  [[ -n "$CF_API_TOKEN" ]] || { read -r -s -p "Cloudflare API token (hidden): " CF_API_TOKEN; echo; }
  [[ -n "$CF_ACCOUNT_ID" ]] || ask "Cloudflare Account ID: " CF_ACCOUNT_ID
  [[ -n "$CF_API_TOKEN" && -n "$CF_ACCOUNT_ID" ]] || die "Token/account ID required."
  API=https://api.cloudflare.com/client/v4
  auth=(-H "Authorization: Bearer $CF_API_TOKEN" -H 'Content-Type: application/json')
  zones="$(curl --fail --silent --show-error "${auth[@]}" "$API/zones?per_page=50")" || die "Could not list zones; check token."
  [[ "$(jq -r .success <<<"$zones")" == true ]] || { jq .errors <<<"$zones"; die "Zone listing failed."; }
  mapfile -t zone_rows < <(jq -r '.result[] | [.id,.name] | @tsv' <<<"$zones")
  ((${#zone_rows[@]})) || die "No zones accessible to token."
  echo "Available zones:"
  for i in "${!zone_rows[@]}"; do printf ' %d) %s\n' "$((i+1))" "$(cut -f2 <<<"${zone_rows[$i]}")"; done
  ask "Choose zone number: " zone_num
  [[ "$zone_num" =~ ^[0-9]+$ ]] && ((zone_num>=1 && zone_num<=${#zone_rows[@]})) || die "Invalid zone number."
  row="${zone_rows[$((zone_num-1))]}"; ZONE_ID="$(cut -f1 <<<"$row")"; ZONE_NAME="$(cut -f2 <<<"$row")"

  ask "Tunnel naming mode [sequential/random] (default sequential): " mode
  mode="${mode:-sequential}"
  if [[ "$mode" == random ]]; then suffix="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"; num=""; else
    COUNTER="$STATE_DIR/tunnel-counter"; num=1; [[ ! -f "$COUNTER" ]] || num="$(cat "$COUNTER")"
    [[ "$num" =~ ^[0-9]+$ ]] || num=1; suffix="$num"
  fi
  TUNNEL_NAME="vpn-${suffix}"; SUBDOMAIN="vpn-${suffix}"
  ask "Tunnel name [$TUNNEL_NAME], Enter to accept: " chosen; [[ -z "$chosen" ]] || TUNNEL_NAME="$chosen"
  ask "Subdomain label [$SUBDOMAIN], Enter to accept: " chosen; [[ -z "$chosen" ]] || SUBDOMAIN="$chosen"
  [[ "$TUNNEL_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$ ]] || die "Invalid tunnel name."
  [[ "$SUBDOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || die "Invalid subdomain label."
  HOSTNAME="${SUBDOMAIN}.${ZONE_NAME}"

  # Cloudflare API-created remotely managed tunnel; retrieve its run token from API.
  secret="$(openssl rand -base64 32 | tr -d '\n')"
  payload="$(jq -n --arg name "$TUNNEL_NAME" --arg secret "$secret" '{name:$name,tunnel_secret:$secret,config_src:"cloudflare"}')"
  created="$(curl --fail --silent --show-error -X POST "${auth[@]}" --data "$payload" "$API/accounts/$CF_ACCOUNT_ID/cfd_tunnel")" || die "Tunnel create API failed."
  [[ "$(jq -r .success <<<"$created")" == true ]] || { jq .errors <<<"$created"; die "Tunnel create failed (name may already exist)."; }
  TUNNEL_ID="$(jq -r .result.id <<<"$created")"
  token_result="$(curl --fail --silent --show-error "${auth[@]}" "$API/accounts/$CF_ACCOUNT_ID/cfd_tunnels/$TUNNEL_ID/token")" || die "Could not retrieve tunnel run token."
  [[ "$(jq -r .success <<<"$token_result")" == true ]] || { jq .errors <<<"$token_result"; die "Tunnel token retrieval failed."; }
  TUNNEL_TOKEN="$(jq -r .result <<<"$token_result")"
  [[ -n "$TUNNEL_TOKEN" && "$TUNNEL_TOKEN" != null ]] || die "Empty tunnel token."
  install -d -m 700 /etc/cloudflared
  printf 'TUNNEL_TOKEN=%s\n' "$TUNNEL_TOKEN" > /etc/cloudflared/tunnel-token.env
  chmod 600 /etc/cloudflared/tunnel-token.env

  dns_payload="$(jq -n --arg name "$HOSTNAME" --arg content "$TUNNEL_ID.cfargotunnel.com" '{type:"CNAME",name:$name,content:$content,proxied:true,ttl:1}')"
  dns="$(curl --fail --silent --show-error -X POST "${auth[@]}" --data "$dns_payload" "$API/zones/$ZONE_ID/dns_records")" || die "DNS create failed."
  [[ "$(jq -r .success <<<"$dns")" == true ]] || { jq .errors <<<"$dns"; die "DNS creation failed; record may already exist."; }
  ingress="$(jq -n --arg host "$HOSTNAME" '{config:{ingress:[{hostname:$host,service:"http://127.0.0.1:80"},{service:"http_status:404"}]}}')"
  result="$(curl --fail --silent --show-error -X PUT "${auth[@]}" --data "$ingress" "$API/accounts/$CF_ACCOUNT_ID/cfd_tunnels/$TUNNEL_ID/configurations")" || die "Tunnel ingress update failed."
  [[ "$(jq -r .success <<<"$result")" == true ]] || { jq .errors <<<"$result"; die "Tunnel ingress update failed."; }

  if [[ ! -x "$CF_BIN" ]]; then
    arch="$(dpkg --print-architecture)"
    case "$arch" in amd64) cfarch=amd64;; arm64) cfarch=arm64;; armhf) cfarch=arm;; *) die "Unsupported architecture: $arch";; esac
    curl --fail --location --retry 3 --retry-all-errors "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cfarch}" -o "$CF_BIN"
    chmod 755 "$CF_BIN"
  fi
  cat > "/etc/systemd/system/${CF_SERVICE}.service" <<EOF
[Unit]
Description=Cloudflare Tunnel $TUNNEL_NAME
After=network-online.target
Wants=network-online.target
[Service]
EnvironmentFile=/etc/cloudflared/tunnel-token.env
ExecStart=$CF_BIN tunnel run --token \${TUNNEL_TOKEN}
Restart=on-failure
RestartSec=5
User=root
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$CF_SERVICE"
  [[ "$mode" != sequential ]] || echo "$((num+1))" > "$COUNTER"
  printf 'TUNNEL_NAME=%q\nTUNNEL_ID=%q\nHOSTNAME=%q\n' "$TUNNEL_NAME" "$TUNNEL_ID" "$HOSTNAME" > "$STATE_DIR/cloudflare.env"
  chmod 600 "$STATE_DIR/cloudflare.env"
  unset CF_API_TOKEN TUNNEL_TOKEN
else
  echo "Skipping Cloudflare because SKIP_CLOUDFLARE=true"
fi

say "Final status"
systemctl --no-pager --full status "$XRAY_SERVICE" "$APP_SERVICE" nginx ssh || true
[[ "${SKIP_CLOUDFLARE:-false}" == true ]] || systemctl --no-pager --full status "$CF_SERVICE" || true
echo "VLESS UUID: $VLESS_UUID"
echo "VMess UUID: $VMESS_UUID"
echo "SSH account: andreas / andreas (weak default password; change immediately with: passwd andreas)"
if [[ -f "$STATE_DIR/cloudflare.env" ]]; then source "$STATE_DIR/cloudflare.env"; echo "Tunnel: $TUNNEL_NAME ($TUNNEL_ID)"; echo "URL: https://$HOSTNAME"; fi
echo "Logs: $LOG and journalctl -u $APP_SERVICE -f"
