#!/usr/bin/env bash
set -euo pipefail

binary=${1:?usage: ci-smoke.sh /path/to/sing-box}
tmp=$(mktemp -d)
pid=
cleanup() {
  if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

reality=$($binary generate reality-keypair)
private=$(awk '/PrivateKey:/ {print $NF}' <<< "$reality")
uuid=$(cat /proc/sys/kernel/random/uuid)
password=$(openssl rand -base64 32 | tr -d '\n')
openssl req -x509 -newkey ed25519 -nodes -days 1 -subj '/CN=localhost' \
  -addext 'subjectAltName=DNS:localhost' -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1

jq -n \
  --arg private "$private" --arg uuid "$uuid" --arg password "$password" \
  --arg cert "$tmp/cert.pem" --arg key "$tmp/key.pem" \
  '{log:{level:"warn"},
    inbounds:[
      {type:"shadowsocks",tag:"ci-ss",listen:"127.0.0.1",listen_port:18441,network:"tcp",method:"2022-blake3-chacha20-poly1305",password:$password},
      {type:"vless",tag:"ci-reality",listen:"127.0.0.1",listen_port:18442,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:"www.example.com",reality:{enabled:true,handshake:{server:"www.example.com",server_port:443},private_key:$private,short_id:["01234567"]}}},
      {type:"hysteria2",tag:"ci-hy2",listen:"127.0.0.1",listen_port:18443,users:[{password:$password}],tls:{enabled:true,certificate_path:$cert,key_path:$key}}
    ],outbounds:[{type:"direct",tag:"direct"}],route:{final:"direct"}}' > "$tmp/config.json"

"$binary" check -c "$tmp/config.json"
"$binary" run -c "$tmp/config.json" >"$tmp/service.log" 2>&1 &
pid=$!
for _ in {1..20}; do
  kill -0 "$pid" 2>/dev/null || { cat "$tmp/service.log" >&2; exit 1; }
  if ss -H -lntu | grep -qE ':(18441|18442|18443)([[:space:]]|$)'; then break; fi
  sleep 0.25
done
for port in 18441 18442 18443; do
  ss -H -lntu | grep -qE ":${port}([[:space:]]|$)" || { cat "$tmp/service.log" >&2; exit 1; }
done
kill "$pid"
wait "$pid" || true
pid=
echo 'all three inbound types validate and bind their expected local ports'
