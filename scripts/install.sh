#!/bin/sh
set -eu

REPO=Catbully/sing-box-alpine-nat
PROJECT_VERSION=${SINGBOX_RELEASE_TAG:-v1.0.1}
SB_VERSION=1.14.2
PREFIX=/usr/local
CONFIG_DIR=/etc/sing-box
BACKUP_DIR=/var/lib/singbox-manager/backups
TMP=$(mktemp -d /var/tmp/singbox-install.XXXXXX)
BIN_STAGE=/usr/local/bin/.sing-box.$$.new
trap 'rm -rf "$TMP"; rm -f "$BIN_STAGE"' 0
trap 'exit 1' HUP INT TERM
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die '请以 root 运行。'
[ -r /etc/alpine-release ] || die '仅支持 Alpine Linux。'
command -v rc-update >/dev/null 2>&1 || die '需要 OpenRC。'
for cmd in awk curl df install sha256sum tar; do command -v "$cmd" >/dev/null 2>&1 || die "缺少命令：$cmd"; done
[ ! -e /etc/init.d/sing-box ] || grep -q 'managed-by sing-box-alpine-nat' /etc/init.d/sing-box || die '检测到非本工具管理的 sing-box OpenRC 服务；为避免覆盖现有服务，安装已停止。'

case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64) arch=arm64 ;;
    i386|i486|i586|i686) arch=386 ;;
    armv7l|armv7) arch=armv7 ;;
    *) die "不支持的 CPU 架构：$(uname -m)" ;;
esac

printf 'Alpine %s / %s\n' "$(cat /etc/alpine-release)" "$arch"
if [ -r /sys/fs/cgroup/memory.max ]; then
    printf 'cgroup memory.max: %s bytes\n' "$(cat /sys/fs/cgroup/memory.max)"
elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
    printf 'cgroup memory limit: %s bytes\n' "$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"
else
    printf 'cgroup memory limit unavailable; host memory is not a container limit.\n'
fi
df -Pk /usr/local /etc /var

asset="sing-box-v${SB_VERSION}-linux-${arch}.tar.gz"
base="https://github.com/${REPO}/releases/download/${PROJECT_VERSION}"
curl --fail --location --proto '=https' --tlsv1.2 --output "$TMP/$asset" "$base/$asset" || die 'Release 下载失败。'
curl --fail --location --proto '=https' --tlsv1.2 --output "$TMP/$asset.sha256" "$base/$asset.sha256" || die 'SHA-256 清单下载失败。'
expected=$(awk 'NR == 1 { print $1 }' "$TMP/$asset.sha256")
actual=$(sha256sum "$TMP/$asset" | awk '{ print $1 }')
[ -n "$expected" ] && [ "$expected" = "$actual" ] || die 'SHA-256 校验失败。'
tar -tzf "$TMP/$asset" | grep -qx sing-box || die '发布包缺少 sing-box 二进制。'
tar -xzf "$TMP/$asset" -C "$TMP"
"$TMP/sing-box" version | grep -F "$SB_VERSION" >/dev/null || die '二进制版本不匹配。'
available_kb=$(df -Pk "$PREFIX" | awk 'END { print $4 }')
archive_bytes=$(wc -c < "$TMP/$asset")
binary_bytes=$(wc -c < "$TMP/sing-box")
old_bytes=0
config_bytes=0
[ ! -f "$PREFIX/bin/sing-box" ] || old_bytes=$(wc -c < "$PREFIX/bin/sing-box")
[ ! -f "$CONFIG_DIR/config.json" ] || config_bytes=$(wc -c < "$CONFIG_DIR/config.json")
required_kb=$(((archive_bytes + binary_bytes + old_bytes + config_bytes + 4194304) / 1024))
[ "$available_kb" -ge "$required_kb" ] || die "磁盘空间不足：需要约 ${required_kb} KiB，可用 ${available_kb} KiB。"

install -d -m 0755 "$PREFIX/bin" "$PREFIX/sbin"
install -d -m 0700 "$CONFIG_DIR" "$CONFIG_DIR/certs" "$BACKUP_DIR"
chmod 0700 "$CONFIG_DIR" "$CONFIG_DIR/certs" "$BACKUP_DIR"
if [ -f "$CONFIG_DIR/config.json" ]; then
    cp -p "$CONFIG_DIR/config.json" "$BACKUP_DIR/config-install-$(date -u '+%Y%m%dT%H%M%SZ').json"
    chmod 0600 "$BACKUP_DIR"/config-install-*.json
fi
if [ -x "$PREFIX/bin/sing-box" ]; then cp -p "$PREFIX/bin/sing-box" "$TMP/sing-box.previous"; fi
install -m 0755 "$TMP/sing-box" "$TMP/sing-box.new"
install -m 0755 "$TMP/singbox-manager.sh" "$PREFIX/sbin/singbox-manager"
install -m 0755 "$TMP/sing-box.initd" /etc/init.d/sing-box
install -m 0755 "$TMP/sing-box" "$BIN_STAGE"
mv -f "$BIN_STAGE" "$PREFIX/bin/sing-box"

if [ -f "$CONFIG_DIR/config.json" ]; then
    if ! "$PREFIX/bin/sing-box" check -c "$CONFIG_DIR/config.json"; then
        if [ -f "$TMP/sing-box.previous" ]; then
            install -m 0755 "$TMP/sing-box.previous" "$BIN_STAGE"
            mv -f "$BIN_STAGE" "$PREFIX/bin/sing-box"
        fi
        die '现有配置验证失败，已恢复旧二进制。'
    fi
else
    umask 077
    cat > "$CONFIG_DIR/config.json" <<'JSON'
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": { "final": "direct" }
}
JSON
    chmod 0600 "$CONFIG_DIR/config.json"
fi
chmod 0600 "$CONFIG_DIR/config.json"
rc-update add sing-box default
printf '安装完成。运行 /usr/local/sbin/singbox-manager 创建节点。\n'
