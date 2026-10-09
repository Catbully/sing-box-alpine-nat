#!/bin/sh
# Alpine/OpenRC manager for one sing-box process with multiple server inbounds.
set -eu

VERSION=1.0.0
SB_VERSION=1.14.2
REPO=Catbully/sing-box-alpine-nat
BIN=/usr/local/bin/sing-box
CONFIG_DIR=/etc/sing-box
CONFIG=$CONFIG_DIR/config.json
CERT_DIR=$CONFIG_DIR/certs
BACKUP_DIR=/var/lib/singbox-manager/backups
LOCK=/var/run/singbox-manager.lock
SERVICE=sing-box
SECURE_DIR=
CREATED_CERT_DIR=
NODE_CREATE_SUCCESS=no

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die '请使用 root 执行。'; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1。请先通过 Alpine 包管理器安装依赖。"; }
say() { printf '%s\n' "$*"; }
cleanup_sensitive() {
    [ -z "$SECURE_DIR" ] || rm -rf -- "$SECURE_DIR"
    if [ "$NODE_CREATE_SUCCESS" != yes ] && [ -n "$CREATED_CERT_DIR" ]; then rm -rf -- "$CREATED_CERT_DIR"; fi
}
trap cleanup_sensitive 0
trap 'exit 1' HUP INT TERM
secure_workspace() {
    [ -z "$SECURE_DIR" ] || rm -rf -- "$SECURE_DIR"
    SECURE_DIR=$(mktemp -d /var/tmp/singbox-sensitive.XXXXXX)
    chmod 0700 "$SECURE_DIR"
}

preflight() {
    [ -r /etc/alpine-release ] || die '仅支持 Alpine Linux。'
    need_root
    command -v rc-service >/dev/null 2>&1 || die '当前环境没有可用的 OpenRC rc-service。'
    for cmd in awk base64 chmod chown date df flock install jq openssl sha256sum stat tar curl ss xxd; do need_cmd "$cmd"; done
    arch=$(uname -m)
    case "$arch" in
        x86_64) asset=amd64 ;;
        aarch64) asset=arm64 ;;
        i386|i486|i586|i686) asset=386 ;;
        armv7l|armv7) asset=armv7 ;;
        *) die "未发布此架构的二进制：$arch" ;;
    esac
    say "Alpine: $(cat /etc/alpine-release); arch=$arch ($asset)"
    if [ -r /sys/fs/cgroup/memory.max ]; then
        say "cgroup memory.max: $(cat /sys/fs/cgroup/memory.max) bytes"
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        say "cgroup memory limit: $(cat /sys/fs/cgroup/memory/memory.limit_in_bytes) bytes"
    else
        say 'cgroup memory limit: unavailable (host memory is not a container limit)'
    fi
    df -Pk /etc /usr/local /var | tail -n +2
}

lock_manager() {
    mkdir -p /var/run
    exec 9>"$LOCK"
    flock -n 9 || die '另一个管理操作正在运行。'
}

ensure_layout() {
    install -d -m 0700 "$CONFIG_DIR" "$CERT_DIR" "$BACKUP_DIR"
    chmod 0700 "$CONFIG_DIR" "$CERT_DIR" "$BACKUP_DIR"
    if [ ! -f "$CONFIG" ]; then
        umask 077
        cat > "$CONFIG" <<'JSON'
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": { "final": "direct" }
}
JSON
        chmod 0600 "$CONFIG"
    fi
    chmod 0600 "$CONFIG"
    for node_dir in "$CERT_DIR"/*; do
        [ -d "$node_dir" ] || continue
        chmod 0700 "$node_dir"
        for cert_file in "$node_dir"/*; do [ -f "$cert_file" ] && chmod 0600 "$cert_file" || :; done
    done
}

backup_config() {
    stamp=$(date -u '+%Y%m%dT%H%M%SZ')-$$
    target="$BACKUP_DIR/config-$stamp.json"
    cp -p "$CONFIG" "$target"
    chmod 0600 "$target"
    for f in "$CERT_DIR"/*; do [ -e "$f" ] && cp -pR "$f" "$BACKUP_DIR/" || :; done
}

prune_backups() {
    # Keep newest five config snapshots, and only prune after a successful apply.
    ls -1t "$BACKUP_DIR"/config-*.json 2>/dev/null | awk 'NR > 5' | while IFS= read -r f; do rm -f -- "$f"; done
}

service_active() { rc-service "$SERVICE" status >/dev/null 2>&1; }

apply_candidate() {
    candidate=$1
    old_active=no
    service_active && old_active=yes || :
    old_enabled=no
    rc-update show default 2>/dev/null | awk '{print $NF}' | grep -qx "$SERVICE" && old_enabled=yes || :
    candidate_nodes=$(jq '.inbounds | length' "$candidate")
    jq -e '(.inbounds | type == "array")
      and ([.inbounds[].tag] | length == (unique | length))
      and ([.inbounds[] | (if .type == "hysteria2" then "udp:" else "tcp:" end) + (.listen_port|tostring)] | length == (unique | length))
      and all(.inbounds[]; (.tag | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$")) and (.listen_port | type == "number" and . >= 1 and . <= 65535))' "$candidate" >/dev/null || die '节点 tag、协议/端口或配置结构校验失败。'
    cert_paths=$(jq -r '.inbounds[]? | select(.type == "hysteria2") | .tls.certificate_path, .tls.key_path' "$candidate")
    for cert_path in $cert_paths; do
        case "$cert_path" in "$CERT_DIR"/*) ;; *) die 'HY2 证书路径必须在管理器证书目录内。' ;; esac
        [ -f "$cert_path" ] || die "HY2 证书文件不存在：$cert_path"
        [ "$(stat -c %a "$cert_path")" = 600 ] && [ "$(stat -c %u "$cert_path")" = 0 ] || die 'HY2 证书和私钥文件必须归 root 所有且权限为 0600。'
    done
    "$BIN" check -c "$candidate" || die '候选配置检查失败；未应用更改。'
    backup_config
    config_tmp="$CONFIG_DIR/.config.$$.tmp"
    cp "$candidate" "$config_tmp"
    chmod 0600 "$config_tmp"
    mv -f "$config_tmp" "$CONFIG"
    apply_service=no
    if [ "$candidate_nodes" -eq 0 ]; then
        [ "$old_active" = no ] || apply_service=stop
    elif [ "$old_active" = yes ]; then
        apply_service=restart
    elif [ "$old_enabled" = yes ]; then
        apply_service=start
    fi
    if [ "$apply_service" != no ]; then
        if ! rc-service "$SERVICE" "$apply_service"; then
            say '应用失败，正在恢复配置备份。' >&2
            latest=$(ls -1t "$BACKUP_DIR"/config-*.json | head -n 1)
            cp "$latest" "$CONFIG_DIR/.rollback.$$.tmp"
            chmod 0600 "$CONFIG_DIR/.rollback.$$.tmp"
            mv -f "$CONFIG_DIR/.rollback.$$.tmp" "$CONFIG"
            if [ "$old_active" = yes ]; then rc-service "$SERVICE" restart || say '警告：恢复后服务仍未启动，请运行“恢复备份”并检查 OpenRC 日志。' >&2; fi
            return 1
        fi
    fi
    if [ "$candidate_nodes" -eq 0 ]; then rc-update del "$SERVICE" default 2>/dev/null || :; fi
    prune_backups
}

random_ss_key() { openssl rand -base64 32 | tr -d '\n'; }
random_uuid() { cat /proc/sys/kernel/random/uuid; }
random_password() { openssl rand -base64 24 | tr -d '\n'; }
reality_public_key() {
    key=$1
    work=$(mktemp -d /var/tmp/reality-key.XXXXXX)
    umask 077
    padded=$(printf '%s' "$key" | tr '_-' '/+')
    case $((${#padded} % 4)) in 2) padded=${padded}== ;; 3) padded=${padded}= ;; esac
    printf '%s' "$padded" | base64 -d > "$work/raw"
    [ "$(wc -c < "$work/raw")" -eq 32 ] || { rm -rf "$work"; return 1; }
    { printf '302e020100300506032b656e04220420' | xxd -r -p; cat "$work/raw"; } > "$work/private.der"
    openssl pkey -inform DER -in "$work/private.der" -pubout -outform DER > "$work/public.der" 2>/dev/null || { rm -rf "$work"; return 1; }
    public=$(tail -c 32 "$work/public.der" | base64 | tr -d '\n=' | tr '+/' '-_')
    rm -rf "$work"
    printf '%s' "$public"
}

port_available() {
    p=$1 proto=$2
    case "$p" in ''|*[!0-9]*) return 1 ;; esac
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || return 1
    if [ "$proto" = tcp ]; then
        ! ss -H -lnt "sport = :$p" | grep -q . || return 1
    else
        ! ss -H -lnu "sport = :$p" | grep -q . || return 1
    fi
    ! jq -e --argjson p "$p" --arg proto "$proto" '.inbounds[]? | select(.listen_port == $p and ((.type == "hysteria2") == ($proto == "udp")))' "$CONFIG" >/dev/null
}

node_summary() {
    jq -r '.inbounds[]? | [.tag, .type, (.listen_port|tostring), (if .type == "hysteria2" then "UDP" else "TCP" end)] | @tsv' "$CONFIG"
}

create_node() {
    need_root; preflight; lock_manager; ensure_layout
    NODE_CREATE_SUCCESS=no
    CREATED_CERT_DIR=
    say '新增节点会重启整个 sing-box 服务，短暂中断全部连接。'
    printf '节点名称（唯一、英文/数字/短横线）：'; IFS= read -r name
    printf '%s' "$name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$' || die '名称格式无效。'
    jq -e --arg n "$name" '[.inbounds[]?.tag] | index($n) == null' "$CONFIG" >/dev/null || die '节点名称已存在。'
    printf '协议 [1] SS2022 TCP [2] VLESS Reality TCP [3] Hysteria2 UDP：'; IFS= read -r choice
    case "$choice" in 1) type=ss proto=tcp ;; 2) type=vless proto=tcp ;; 3) type=hysteria2 proto=udp ;; *) die '协议选项无效。' ;; esac
    printf '内部监听端口：'; IFS= read -r port
    port_available "$port" "$proto" || die '端口无效、已占用或与现有节点冲突。'

    secure_workspace
    credential_file="$SECURE_DIR/credentials.json"
    inbound_file="$SECURE_DIR/inbound.json"
    client_file="$SECURE_DIR/client.yaml"
    case "$type" in
        ss)
            secret=$(random_ss_key)
            printf '{"password":"%s"}\n' "$secret" > "$credential_file"
            jq -cn --arg n "$name" --argjson p "$port" --slurpfile c "$credential_file" '{type:"shadowsocks",tag:$n,listen:"0.0.0.0",listen_port:$p,network:"tcp",method:"2022-blake3-chacha20-poly1305",password:$c[0].password}' > "$inbound_file"
            jq -r --arg n "$name" --slurpfile c "$credential_file" '"proxies:\n  - name: \"\($n)\"\n    type: ss\n    server: YOUR_SERVER_ADDRESS\n    port: YOUR_EXTERNAL_PORT\n    cipher: 2022-blake3-chacha20-poly1305\n    password: \"\($c[0].password)\"\n    udp: false"' > "$client_file"
            ;;
        vless)
            printf 'Reality 握手目标域名（有效 TLS 站点）：'; IFS= read -r sni
            printf '%s' "$sni" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$' || die '域名格式无效。'
            openssl s_client -connect "$sni:443" -servername "$sni" -verify 5 -verify_return_error -verify_hostname "$sni" </dev/null >/dev/null 2>&1 || die 'Reality 握手目标无法完成已验证的 TLS 握手。'
            key_output=$("$BIN" generate reality-keypair) || die 'Reality 密钥对生成失败。'
            private_key=$(printf '%s\n' "$key_output" | awk -F': *' '/PrivateKey:/ {print $2}')
            public_key=$(printf '%s\n' "$key_output" | awk -F': *' '/PublicKey:/ {print $2}')
            [ -n "$private_key" ] && [ -n "$public_key" ] || die '无法读取 Reality 密钥对。'
            short_id=$(openssl rand -hex 4)
            uuid=$(random_uuid)
            printf '{"uuid":"%s","private_key":"%s","public_key":"%s","short_id":"%s"}\n' "$uuid" "$private_key" "$public_key" "$short_id" > "$credential_file"
            jq -cn --arg n "$name" --argjson p "$port" --arg sn "$sni" --slurpfile c "$credential_file" '{type:"vless",tag:$n,listen:"0.0.0.0",listen_port:$p,users:[{name:$n,uuid:$c[0].uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$sn,reality:{enabled:true,handshake:{server:$sn,server_port:443},private_key:$c[0].private_key,short_id:[$c[0].short_id]}}}' > "$inbound_file"
            jq -r --arg n "$name" --arg sn "$sni" --slurpfile c "$credential_file" '"proxies:\n  - name: \"\($n)\"\n    type: vless\n    server: YOUR_SERVER_ADDRESS\n    port: YOUR_EXTERNAL_PORT\n    uuid: \($c[0].uuid)\n    network: tcp\n    tls: true\n    servername: \($sn)\n    client-fingerprint: chrome\n    flow: xtls-rprx-vision\n    reality-opts:\n      public-key: \($c[0].public_key)\n      short-id: \($c[0].short_id)"' > "$client_file"
            ;;
        hysteria2)
            printf '证书 SNI 域名：'; IFS= read -r sni
            printf '%s' "$sni" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$' || die '域名格式无效。'
            secret=$(random_password)
            printf '{"password":"%s"}\n' "$secret" > "$credential_file"
            node_cert_dir="$CERT_DIR/$name"
            CREATED_CERT_DIR=$node_cert_dir
            install -d -m 0700 "$node_cert_dir"
            openssl req -x509 -newkey ed25519 -nodes -days 3650 -subj "/CN=$sni" -addext "subjectAltName=DNS:$sni" -keyout "$node_cert_dir/key.pem" -out "$node_cert_dir/cert.pem" >/dev/null 2>&1
            chmod 0600 "$node_cert_dir"/*
            fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "$node_cert_dir/cert.pem" | sed 's/^[^=]*=//')
            jq -cn --arg n "$name" --argjson p "$port" --arg sn "$sni" --arg c "$node_cert_dir/cert.pem" --arg k "$node_cert_dir/key.pem" --slurpfile secret "$credential_file" '{type:"hysteria2",tag:$n,listen:"0.0.0.0",listen_port:$p,users:[{name:$n,password:$secret[0].password}],tls:{enabled:true,server_name:$sn,certificate_path:$c,key_path:$k}}' > "$inbound_file"
            jq -r --arg n "$name" --arg sn "$sni" --arg fp "$fingerprint" --slurpfile c "$credential_file" '"proxies:\n  - name: \"\($n)\"\n    type: hysteria2\n    server: YOUR_SERVER_ADDRESS\n    port: YOUR_EXTERNAL_PORT\n    password: \"\($c[0].password)\"\n    sni: \($sn)\n    skip-cert-verify: false\n    fingerprint: \($fp)"' > "$client_file"
            ;;
    esac

    chmod 0600 "$credential_file" "$inbound_file" "$client_file"
    candidate="$CONFIG_DIR/.candidate.$$.json"
    jq --slurpfile inbound "$inbound_file" '.inbounds += [$inbound[0]]' "$CONFIG" > "$candidate"
    chmod 0600 "$candidate"
    if ! apply_candidate "$candidate"; then rm -f "$candidate"; die '节点未能应用，配置已尝试回滚。'; fi
    rm -f "$candidate"
    NODE_CREATE_SUCCESS=yes
    say '节点已写入本地配置。以下连接信息仅显示一次，请妥善保存：'
    cat "$client_file"
    [ "$type" = hysteria2 ] && say '请在服务商面板将该内部端口配置为 UDP 转发。'
    rm -rf -- "$SECURE_DIR"; SECURE_DIR=
}

delete_node() {
    need_root; preflight; lock_manager; ensure_layout
    node_summary
    printf '输入要删除的节点名称：'; IFS= read -r name
    jq -e --arg n "$name" '.inbounds | any(.tag == $n)' "$CONFIG" >/dev/null || die '找不到该节点。'
    printf '删除 %s 并重启全部入口？输入 yes 确认：' "$name"; IFS= read -r confirm
    [ "$confirm" = yes ] || return 0
    candidate="$CONFIG_DIR/.candidate.$$.json"
    jq --arg n "$name" '.inbounds |= map(select(.tag != $n))' "$CONFIG" > "$candidate"
    chmod 0600 "$candidate"
    apply_candidate "$candidate" || die '删除未应用，已恢复原配置。'
    rm -f "$candidate"
    if [ "$(jq '.inbounds|length' "$CONFIG")" -eq 0 ]; then
        rc-service "$SERVICE" stop || :
        rc-update del "$SERVICE" default 2>/dev/null || :
        say '最后一个节点已删除；服务已停止并取消开机自启。'
    fi
}

edit_node() {
    need_root; preflight; lock_manager; ensure_layout
    node_summary
    printf '输入节点名称：'; IFS= read -r old
    node=$(jq -ce --arg n "$old" '.inbounds[] | select(.tag == $n)' "$CONFIG") || die '找不到该节点。'
    current_port=$(printf '%s\n' "$node" | jq -r .listen_port)
    printf '新节点名称（回车保留）：'; IFS= read -r name
    [ -n "$name" ] || name=$old
    printf '%s' "$name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$' || die '名称格式无效。'
    jq -e --arg old "$old" --arg n "$name" '[.inbounds[]?.tag | select(. != $old)] | index($n) == null' "$CONFIG" >/dev/null || die '节点名称已存在。'
    printf '新内部端口（回车保留 %s）：' "$current_port"; IFS= read -r port
    [ -n "$port" ] || port=$current_port
    type=$(printf '%s\n' "$node" | jq -r .type)
    proto=udp; [ "$type" = hysteria2 ] || proto=tcp
    if [ "$port" != "$current_port" ]; then port_available "$port" "$proto" || die '新端口无效、已占用或与其他节点冲突。'; fi
    case "$port" in ''|*[!0-9]*) die '端口格式无效。' ;; esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die '端口须为 1–65535。'
    candidate="$CONFIG_DIR/.candidate.$$.json"
    jq --arg old "$old" --arg n "$name" --argjson p "$port" '(.inbounds[] | select(.tag == $old)) |= (.tag=$n | .listen_port=$p)' "$CONFIG" > "$candidate"
    chmod 0600 "$candidate"
    apply_candidate "$candidate" || die '节点修改未应用，已恢复原配置。'
    rm -f "$candidate"
}

rotate_credentials() {
    need_root; preflight; lock_manager; ensure_layout
    secure_workspace
    credential_file="$SECURE_DIR/credentials.json"
    node_summary
    printf '输入要重新生成凭据的节点名称：'; IFS= read -r name
    node=$(jq -ce --arg n "$name" '.inbounds[] | select(.tag == $n)' "$CONFIG") || die '找不到该节点。'
    type=$(printf '%s\n' "$node" | jq -r .type)
    case "$type" in
        shadowsocks) secret=$(random_ss_key);;
        vless)
            key_output=$("$BIN" generate reality-keypair) || die 'Reality 密钥对生成失败。'
            private=$(printf '%s\n' "$key_output" | awk -F': *' '/PrivateKey:/ {print $2}')
            uuid=$(random_uuid)
            sid=$(openssl rand -hex 4)
            [ -n "$private" ] || die '无法读取新 Reality 私钥.'
            ;;
        hysteria2) secret=$(random_password);;
        *) die '自定义入口凭据不能安全轮换。';;
    esac
    printf '轮换凭据会立刻重启全部入口并使该节点旧凭据失效。输入 yes 确认：'; IFS= read -r confirm
    [ "$confirm" = yes ] || return 0
    candidate="$CONFIG_DIR/.candidate.$$.json"
    case "$type" in
        shadowsocks)
            printf '{"password":"%s"}\n' "$secret" > "$credential_file"
            jq --arg n "$name" --slurpfile c "$credential_file" '(.inbounds[] | select(.tag == $n)).password = $c[0].password' "$CONFIG" > "$candidate"
            ;;
        vless)
            printf '{"private_key":"%s","short_id":"%s","uuid":"%s"}\n' "$private" "$sid" "$uuid" > "$credential_file"
            jq --arg n "$name" --slurpfile c "$credential_file" '(.inbounds[] | select(.tag == $n)) |= (.users[0].uuid=$c[0].uuid | .tls.reality |= (.private_key=$c[0].private_key | .short_id=[$c[0].short_id]))' "$CONFIG" > "$candidate"
            ;;
        hysteria2)
            printf '{"password":"%s"}\n' "$secret" > "$credential_file"
            jq --arg n "$name" --slurpfile c "$credential_file" '(.inbounds[] | select(.tag == $n)).users[0].password = $c[0].password' "$CONFIG" > "$candidate"
            ;;
    esac
    chmod 0600 "$credential_file"
    chmod 0600 "$candidate"
    apply_candidate "$candidate" || die '凭据轮换未应用，已恢复原配置。'
    rm -f "$candidate"
    say '请立即将旧节点从客户端替换为新导出内容：'
    export_node <<EOF
$name
EOF
    rm -rf -- "$SECURE_DIR"; SECURE_DIR=
}

export_node() {
    need_root; ensure_layout
    node_summary
    printf '输入要导出的节点名称：'; IFS= read -r name
    node=$(jq -ce --arg n "$name" '.inbounds[] | select(.tag == $n)' "$CONFIG") || die '找不到该节点。'
    type=$(printf '%s' "$node" | jq -r .type)
    say '将服务器地址和外部端口替换为你在 NAT 面板配置的值。导出内容含敏感凭据，不要提交到仓库。'
    case "$type" in
        shadowsocks)
            printf '%s\n' "$node" | jq -r '"proxies:\n  - name: \"\(.tag)\"\n    type: ss\n    server: YOUR_SERVER_ADDRESS\n    port: YOUR_EXTERNAL_PORT\n    cipher: \(.method)\n    password: \"\(.password)\"\n    udp: false"'
            ;;
        vless)
            private=$(printf '%s\n' "$node" | jq -r '.tls.reality.private_key')
            public=$(reality_public_key "$private") || die '无法从 Reality 私钥导出公钥。'
            printf '%s\n' "$node" | jq -r --arg pk "$public" '"proxies:\n  - name: \"\(.tag)\"\n    type: vless\n    server: YOUR_SERVER_ADDRESS\n    port: YOUR_EXTERNAL_PORT\n    uuid: \(.users[0].uuid)\n    network: tcp\n    tls: true\n    servername: \(.tls.server_name)\n    client-fingerprint: chrome\n    flow: \(.users[0].flow)\n    reality-opts:\n      public-key: \($pk)\n      short-id: \(.tls.reality.short_id[0])"'
            ;;
        hysteria2)
            cert=$(printf '%s\n' "$node" | jq -r '.tls.certificate_path')
            fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "$cert" | sed 's/^[^=]*=//')
            printf '%s\n' "$node" | jq -r --arg fp "$fingerprint" '"proxies:\n  - name: \"\(.tag)\"\n    type: hysteria2\n    server: YOUR_SERVER_ADDRESS\n    port: YOUR_EXTERNAL_PORT\n    password: \"\(.users[0].password)\"\n    sni: \(.tls.server_name)\n    skip-cert-verify: false\n    fingerprint: \($fp)"'
            ;;
        *) die '自定义节点没有可识别的客户端导出格式。' ;;
    esac
}

edit_json() {
    need_root; preflight; lock_manager; ensure_layout
    editor=${VISUAL:-${EDITOR:-vi}}
    command -v "${editor%% *}" >/dev/null 2>&1 || die "找不到编辑器：${editor%% *}"
    candidate="$CONFIG_DIR/.candidate.$$.json"
    cp "$CONFIG" "$candidate"
    chmod 0600 "$candidate"
    if ! $editor "$candidate"; then rm -f "$candidate"; die '编辑器执行失败；原配置未修改。'; fi
    if ! jq empty "$candidate"; then rm -f "$candidate"; die 'JSON 语法无效；原配置未修改。'; fi
    apply_candidate "$candidate" || die '配置未应用，已恢复备份。'
    rm -f "$candidate"
}

restore_backup() {
    need_root; preflight; lock_manager; ensure_layout
    backups=$(ls -1t "$BACKUP_DIR"/config-*.json 2>/dev/null || :)
    [ -n "$backups" ] || die '没有可恢复的配置备份。'
    printf '%s\n' "$backups"
    printf '输入完整备份文件名：'; IFS= read -r selected
    case "$selected" in "$BACKUP_DIR"/config-*.json) ;; *) die '备份路径无效。' ;; esac
    [ -f "$selected" ] || die '找不到该备份。'
    printf '恢复此备份并应用？输入 yes 确认：'; IFS= read -r confirm
    [ "$confirm" = yes ] || return 0
    candidate="$CONFIG_DIR/.candidate.$$.json"
    cp "$selected" "$candidate"
    chmod 0600 "$candidate"
    apply_candidate "$candidate" || die '恢复失败，当前配置已回滚。'
    rm -f "$candidate"
}

control_service() {
    need_root; preflight
    case "$1" in
        pause) rc-service "$SERVICE" stop; rc-update del "$SERVICE" default 2>/dev/null || : ;;
        start) rc-update add "$SERVICE" default; rc-service "$SERVICE" start ;;
        restart) rc-service "$SERVICE" restart ;;
    esac
}

update_binary() {
    need_root; preflight; lock_manager
    release_tag=${SINGBOX_RELEASE_TAG:-v$VERSION}
    printf '%s' "$release_tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || die '无效的项目 Release tag。'
    url="https://github.com/$REPO/releases/download/$release_tag/sing-box-v$SB_VERSION-linux-$asset.tar.gz"
    tmp=$(mktemp -d /var/tmp/singbox-update.XXXXXX)
    binary_tmp="$BIN.new.$$"
    rollback_tmp="$BIN.rollback.$$"
    trap 'rm -rf "$tmp"; rm -f "${binary_tmp:-}" "${rollback_tmp:-}"; cleanup_sensitive' 0
    trap 'exit 1' HUP INT TERM
    archive="$tmp/sing-box.tar.gz"
    curl --fail --location --proto '=https' --tlsv1.2 --output "$archive" "$url" || die '下载失败。'
    curl --fail --location --proto '=https' --tlsv1.2 --output "$tmp/checksum" "$url.sha256" || die '校验清单下载失败。'
    expected=$(awk 'NR == 1 {print $1}' "$tmp/checksum")
    actual=$(sha256sum "$archive" | awk '{print $1}')
    [ -n "$expected" ] && [ "$actual" = "$expected" ] || die 'SHA-256 不匹配。'
    tar -tzf "$archive" | grep -qx sing-box || die 'Release 包内容不符合预期。'
    tar -xzf "$archive" -C "$tmp"
    [ "$($tmp/sing-box version | head -n1 | grep -F "$SB_VERSION" || :)" ] || die '二进制版本不匹配。'
    [ -x "$BIN" ] || die '管理器尚未安装二进制；请先运行安装流程。'
    available_kb=$(df -Pk /usr/local | awk 'END {print $4}')
    archive_bytes=$(wc -c < "$archive")
    new_bytes=$(wc -c < "$tmp/sing-box")
    old_bytes=$(wc -c < "$BIN")
    config_bytes=0; [ ! -f "$CONFIG" ] || config_bytes=$(wc -c < "$CONFIG")
    required_kb=$(((archive_bytes + new_bytes + old_bytes + config_bytes + 4194304) / 1024))
    [ "$available_kb" -ge "$required_kb" ] || die "磁盘空间不足：需要约 ${required_kb} KiB，可用 ${available_kb} KiB。"
    cp -p "$BIN" "$tmp/sing-box.previous"
    was_active=no; service_active && was_active=yes || :
    install -m 0755 "$tmp/sing-box" "$binary_tmp"
    mv -f "$binary_tmp" "$BIN"
    if [ -f "$CONFIG" ] && ! "$BIN" check -c "$CONFIG"; then
        install -m 0755 "$tmp/sing-box.previous" "$rollback_tmp"
        mv -f "$rollback_tmp" "$BIN"
        die '更新后配置检查失败，已恢复旧二进制。'
    fi
    if [ "$was_active" = yes ] && ! rc-service "$SERVICE" restart; then
        install -m 0755 "$tmp/sing-box.previous" "$rollback_tmp"
        mv -f "$rollback_tmp" "$BIN"
        rc-service "$SERVICE" restart || say '警告：旧二进制已恢复，但服务仍未启动。' >&2
        die '更新重启失败，已恢复旧二进制。'
    fi
    say "已安装 sing-box v$SB_VERSION。"
}

show_status() {
    if [ -x "$BIN" ]; then "$BIN" version | head -n 1; else say 'sing-box 尚未安装。'; fi
    if service_active; then say '服务：运行中'; else say '服务：已停止'; fi
    if [ -f "$CONFIG" ]; then node_summary; else say '无配置'; fi
}

menu() {
    need_root
    while :; do
        printf '\n=== sing-box Alpine 管理器 v%s ===\n' "$VERSION"
        printf '1 状态/节点  2 新增节点  3 编辑节点  4 删除节点  5 导出 Nikki 节点\n'
        printf '6 轮换节点凭据  7 暂停服务  8 启动服务  9 重启服务  10 手动更新二进制\n'
        printf '11 编辑原始 JSON  12 恢复配置备份  0 退出\n选择：'
        IFS= read -r choice || exit 0
        case "$choice" in
            1) show_status ;;
            2) create_node ;;
            3) edit_node ;;
            4) delete_node ;;
            5) export_node ;;
            6) rotate_credentials ;;
            7) control_service pause ;;
            8) control_service start ;;
            9) control_service restart ;;
            10) update_binary ;;
            11) edit_json ;;
            12) restore_backup ;;
            0) exit 0 ;;
            *) say '无效选项。' ;;
        esac
    done
}

case "${1:-menu}" in
    menu) menu ;;
    status) need_root; ensure_layout; show_status ;;
    update) update_binary ;;
    *) die "用法：$0 [menu|status|update]" ;;
esac
