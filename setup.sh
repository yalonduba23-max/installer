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
CRED_HOME=/root/makeli-server
MANAGER=/usr/local/sbin/makeli-manage
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
SSH_USER="${SSH_USER:-makeli$(od -An -N3 -tu4 /dev/urandom | tr -d ' ')}"
SSH_PASS="${SSH_PASS:-$(openssl rand -hex 10)}"
if ! id "$SSH_USER" >/dev/null 2>&1; then useradd -m -d "/home/$SSH_USER" -s /usr/sbin/nologin "$SSH_USER"; fi
printf '%s:%s\n' "$SSH_USER" "$SSH_PASS" | chpasswd
passwd -u "$SSH_USER" >/dev/null 2>&1 || true
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
        for c in data[proto]: print(f'  {c["name"]}: {c["uuid"]} | expires={c["expires"] or "never"}')
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
  CF_API_TOKEN="${CF_API_TOKEN:-}"
  CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-}"
  [[ -n "$CF_API_TOKEN" && -n "$CF_ACCOUNT_ID" ]] || die "Set CF_API_TOKEN and CF_ACCOUNT_ID in .env; setup runs non-interactively."
  API=https://api.cloudflare.com/client/v4
  auth=(-H "Authorization: Bearer $CF_API_TOKEN" -H 'Content-Type: application/json')
  zones="$(curl --fail --silent --show-error "${auth[@]}" "$API/zones?per_page=50")" || die "Could not list zones; check token."
  [[ "$(jq -r .success <<<"$zones")" == true ]] || { jq .errors <<<"$zones"; die "Zone listing failed."; }

  # Use the requested default zone automatically.
  DEFAULT_ZONE="freessh.indevs.in"
  ZONE_ID="$(jq -r --arg name "$DEFAULT_ZONE" '.result[] | select(.name == $name) | .id' <<<"$zones" | head -n1)"
  if [[ -z "$ZONE_ID" ]]; then
    echo "The default zone '$DEFAULT_ZONE' was not found in the zones accessible to this API token."
    echo "Available zones:"
    jq -r '.result[] | " - " + .name' <<<"$zones"
    die "Make sure the token can access '$DEFAULT_ZONE' and has Zone:Read and DNS:Edit permissions."
  fi
  ZONE_NAME="$DEFAULT_ZONE"
  echo "Using Cloudflare zone: $ZONE_NAME"

  # Find the first unused ws-serverN tunnel name and DNS hostname.
  # This checks Cloudflare itself, so separate servers do not all default to ws-server1.
  tunnels="$(curl --fail --silent --show-error "${auth[@]}" "$API/accounts/$CF_ACCOUNT_ID/cfd_tunnels?per_page=100")" || die "Could not list existing Cloudflare tunnels."
  [[ "$(jq -r .success <<<"$tunnels")" == true ]] || { jq .errors <<<"$tunnels"; die "Tunnel listing failed."; }

  num=1
  while :; do
    TUNNEL_NAME="ws-server${num}"
    SUBDOMAIN="ws-server${num}"
    HOSTNAME="${SUBDOMAIN}.${ZONE_NAME}"

    tunnel_exists="$(jq -r --arg name "$TUNNEL_NAME" '[.result[] | select(.name == $name)] | length' <<<"$tunnels")"
    dns_check="$(curl --fail --silent --show-error -G "${auth[@]}" \
      --data-urlencode "name=$HOSTNAME" "$API/zones/$ZONE_ID/dns_records")" || die "Could not check DNS record '$HOSTNAME'."
    [[ "$(jq -r .success <<<"$dns_check")" == true ]] || { jq .errors <<<"$dns_check"; die "DNS lookup failed."; }
    dns_exists="$(jq -r '.result | length' <<<"$dns_check")"

    if [[ "$tunnel_exists" == 0 && "$dns_exists" == 0 ]]; then
      break
    fi
    num=$((num + 1))
  done

  echo "Automatically selected tunnel: $TUNNEL_NAME"
  echo "Automatically selected hostname: $HOSTNAME"
  # Cloudflare API-created remotely managed tunnel; retrieve its run token from API.
  secret="$(openssl rand -base64 32 | tr -d '\n')"
  payload="$(jq -n --arg name "$TUNNEL_NAME" --arg secret "$secret" '{name:$name,tunnel_secret:$secret,config_src:"cloudflare"}')"
  created="$(curl --fail --silent --show-error -X POST "${auth[@]}" --data "$payload" "$API/accounts/$CF_ACCOUNT_ID/cfd_tunnel")" || die "Tunnel create API failed."
  [[ "$(jq -r .success <<<"$created")" == true ]] || { jq .errors <<<"$created"; die "Tunnel create failed (name may already exist)."; }
  TUNNEL_ID="$(jq -r .result.id <<<"$created")"
  token_result="$(curl --fail --silent --show-error "${auth[@]}" "$API/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/token")" || die "Could not retrieve tunnel run token."
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
  result="$(curl --fail --silent --show-error -X PUT "${auth[@]}" --data "$ingress" "$API/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations")" || die "Tunnel ingress update failed."
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
  printf 'TUNNEL_NAME=%q\nTUNNEL_ID=%q\nHOSTNAME=%q\n' "$TUNNEL_NAME" "$TUNNEL_ID" "$HOSTNAME" > "$STATE_DIR/cloudflare.env"
  chmod 600 "$STATE_DIR/cloudflare.env"
  unset CF_API_TOKEN TUNNEL_TOKEN
else
  echo "Skipping Cloudflare because SKIP_CLOUDFLARE=true"
fi

# Seed the managed-client database with the installer-created UUIDs.
if [[ ! -f /var/lib/vpn-ws-setup/managed-clients.json ]]; then
  jq -n --arg vu "$VLESS_UUID" --arg mu "$VMESS_UUID" '{vless:[{name:"default",uuid:$vu,expires:null}],vmess:[{name:"default",uuid:$mu,expires:null}]}' > /var/lib/vpn-ws-setup/managed-clients.json
  chmod 600 /var/lib/vpn-ws-setup/managed-clients.json
fi
cat > /etc/systemd/system/makeli-expiry.service <<EOF
[Unit]
Description=Expire Makeli VLESS/VMess clients
[Service]
Type=oneshot
ExecStart=$MANAGER expire
EOF
cat > /etc/systemd/system/makeli-expiry.timer <<'EOF'
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
systemctl enable --now makeli-expiry.timer
printf 'SSH_USER=%s\nSSH_PASS=%s\n' "$SSH_USER" "$SSH_PASS" > "$CRED_HOME/ssh-creds.txt"
chmod 600 "$CRED_HOME/ssh-creds.txt"

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
