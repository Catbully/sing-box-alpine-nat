#!/bin/sh
set -eu

CONFIG=/etc/sing-box/config.json

die() { printf '错误：%s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die '请使用 root 执行。'
[ -r "$CONFIG" ] || die "找不到 sing-box 配置：$CONFIG"
command -v jq >/dev/null 2>&1 || die '缺少 jq，请先安装 jq。'

nodes=$(jq -r '.inbounds[]? | select(.type == "shadowsocks" and .method == "2022-blake3-chacha20-poly1305") | [.tag, (.listen_port|tostring)] | @tsv' "$CONFIG")
[ -n "$nodes" ] || die '没有找到 SS2022 节点。'

printf '可导出的 SS2022 节点（名称 / 内部端口）：\n%s\n' "$nodes"
printf '输入节点名称：'
IFS= read -r name
node=$(jq -ce --arg n "$name" '.inbounds[] | select(.tag == $n and .type == "shadowsocks" and .method == "2022-blake3-chacha20-poly1305")' "$CONFIG") || die '找不到该 SS2022 节点。'

printf '服务器地址（IP 或域名）：'
IFS= read -r server
[ -n "$server" ] || die '服务器地址不能为空。'

printf 'NAT 外部 TCP 端口（映射到节点内部端口）：'
IFS= read -r external_port
case "$external_port" in ''|*[!0-9]*) die '端口必须是 1 到 65535 的数字。' ;; esac
[ "$external_port" -ge 1 ] && [ "$external_port" -le 65535 ] || die '端口必须是 1 到 65535。'

printf '%s\n' "$node" | jq -r --arg server "$server" --argjson port "$external_port" '"proxies:\n  - name: \(.tag|tojson)\n    type: ss\n    server: \($server|tojson)\n    port: \($port)\n    cipher: \(.method|tojson)\n    password: \(.password|tojson)\n    udp: false"'
printf '%s\n' '以上配置包含敏感凭据，请妥善保存，不要公开分享。' >&2
