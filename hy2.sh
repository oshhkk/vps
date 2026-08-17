#!/usr/bin/env bash
# -*- coding: utf-8 -*-

# Hysteria 2 v2.11.0
# Cloudflare DNS-01 ACME + systemd
#
# 用法：
#   bash install-hy2.sh <域名> <邮箱> [端口]
#
# 示例：
#   bash install-hy2.sh hy2.example.com you@example.com 443

set -euo pipefail

# ============================================================
# 基本配置
# ============================================================

HYSTERIA_VERSION="v2.11.0"

DOMAIN="${1:-}"
EMAIL="${2:-}"
SERVER_PORT="${3:-443}"

INSTALL_DIR="/opt/hysteria"
CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
SERVICE_FILE="/etc/systemd/system/hysteria-server.service"

HYSTERIA_USER="hysteria"
HYSTERIA_GROUP="hysteria"

# ============================================================
# 检查参数
# ============================================================

if [[ -z "$DOMAIN" || -z "$EMAIL" ]]; then
    echo "用法："
    echo "  bash $0 <域名> <邮箱> [端口]"
    echo
    echo "示例："
    echo "  bash $0 hy2.example.com you@example.com 443"
    exit 1
fi

if ! [[ "$SERVER_PORT" =~ ^[0-9]+$ ]] || \
   (( SERVER_PORT < 1 || SERVER_PORT > 65535 )); then
    echo "❌ 端口无效：$SERVER_PORT"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "❌ 请使用 root 用户执行。"
    exit 1
fi

# ============================================================
# 获取 Cloudflare API Token
# ============================================================

echo
echo "============================================================"
echo "Cloudflare API Token"
echo "============================================================"
echo
echo "请输入 Cloudflare API Token。"
echo "输入时不会显示在屏幕上。"
echo

read -r -s -p "Cloudflare API Token: " CF_API_TOKEN
echo

if [[ -z "$CF_API_TOKEN" ]]; then
    echo "❌ Cloudflare API Token 不能为空。"
    exit 1
fi

# ============================================================
# 生成随机密码
# ============================================================

AUTH_PASSWORD="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)"

if [[ -z "$AUTH_PASSWORD" ]]; then
    echo "❌ 无法生成随机密码。"
    exit 1
fi

# ============================================================
# 检查依赖
# ============================================================

echo
echo "============================================================"
echo "检查系统环境"
echo "============================================================"

for cmd in curl bash systemctl openssl uname; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ 缺少依赖：$cmd"
        exit 1
    fi
done

echo "✅ 基础依赖检查完成"

# ============================================================
# 检测 CPU 架构
# ============================================================

MACHINE="$(uname -m)"

case "$MACHINE" in
    x86_64|amd64)
        ARCH="amd64"
        ;;
    aarch64|arm64)
        ARCH="arm64"
        ;;
    *)
        echo "❌ 暂不支持的 CPU 架构：$MACHINE"
        exit 1
        ;;
esac

BINARY_NAME="hysteria-linux-${ARCH}"
BINARY_PATH="${INSTALL_DIR}/hysteria"

echo "✅ CPU 架构：$ARCH"

# ============================================================
# 创建用户和目录
# ============================================================

echo
echo "============================================================"
echo "创建 Hysteria 用户和目录"
echo "============================================================"

if ! getent group "$HYSTERIA_GROUP" >/dev/null 2>&1; then
    groupadd --system "$HYSTERIA_GROUP"
fi

if ! id "$HYSTERIA_USER" >/dev/null 2>&1; then
    useradd \
        --system \
        --gid "$HYSTERIA_GROUP" \
        --no-create-home \
        --home-dir /nonexistent \
        --shell /usr/sbin/nologin \
        "$HYSTERIA_USER"
fi

mkdir -p "$INSTALL_DIR"
mkdir -p "$CONFIG_DIR"

chown root:root "$INSTALL_DIR"
chmod 755 "$INSTALL_DIR"

chown root:"$HYSTERIA_GROUP" "$CONFIG_DIR"
chmod 750 "$CONFIG_DIR"

# ============================================================
# 下载 Hysteria
# ============================================================

echo
echo "============================================================"
echo "下载 Hysteria ${HYSTERIA_VERSION}"
echo "============================================================"

DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${BINARY_NAME}"

echo "下载地址："
echo "$DOWNLOAD_URL"
echo

curl -fL \
    --retry 3 \
    --connect-timeout 30 \
    -o "$BINARY_PATH" \
    "$DOWNLOAD_URL"

chmod 755 "$BINARY_PATH"
chown root:root "$BINARY_PATH"

echo
echo "✅ Hysteria 下载完成"

# ============================================================
# 检查版本
# ============================================================

echo
echo "============================================================"
echo "检查 Hysteria 版本"
echo "============================================================"

"$BINARY_PATH" version || true

# ============================================================
# 写入配置
# ============================================================

echo
echo "============================================================"
echo "生成 Hysteria 配置"
echo "============================================================"

cat > "$CONFIG_FILE" <<EOF
listen: ":${SERVER_PORT}"

acme:
  domains:
    - "${DOMAIN}"
  email: "${EMAIL}"
  type: dns
  dns:
    name: cloudflare
    config:
      cloudflare_api_token: "${CF_API_TOKEN}"

auth:
  type: password
  password: "${AUTH_PASSWORD}"

bandwidth:
  up: "200mbps"
  down: "200mbps"
EOF

chown root:"$HYSTERIA_GROUP" "$CONFIG_FILE"
chmod 640 "$CONFIG_FILE"

echo "✅ 配置文件：$CONFIG_FILE"

# ============================================================
# 创建 systemd 服务
# ============================================================

echo
echo "============================================================"
echo "创建 systemd 服务"
echo "============================================================"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Hysteria 2 Server
Documentation=https://v2.hysteria.network/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

User=${HYSTERIA_USER}
Group=${HYSTERIA_GROUP}

ExecStart=${BINARY_PATH} server -c ${CONFIG_FILE}

Restart=on-failure
RestartSec=5s

# 如果使用 443 等低端口，允许绑定低端口。
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# 基本安全限制
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "$SERVICE_FILE"

systemctl daemon-reload

# ============================================================
# 启动服务
# ============================================================

echo
echo "============================================================"
echo "启动 Hysteria"
echo "============================================================"

systemctl enable hysteria-server.service
systemctl restart hysteria-server.service

sleep 3

# ============================================================
# 检查状态
# ============================================================

echo
echo "============================================================"
echo "检查服务状态"
echo "============================================================"

if systemctl is-active --quiet hysteria-server.service; then
    echo "✅ Hysteria 启动成功"
else
    echo "❌ Hysteria 启动失败"
    echo
    echo "最近日志："
    journalctl --no-pager -n 50 -u hysteria-server.service
    exit 1
fi

# ============================================================
# 获取服务器 IP
# ============================================================

SERVER_IP="$(curl -4 -s --max-time 10 https://api.ipify.org || true)"

if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="你的VPS_IP"
fi

# ============================================================
# 输出信息
# ============================================================

echo
echo
echo "================================================================"
echo "                 Hysteria 2 部署完成"
echo "================================================================"
echo
echo "Hysteria 版本：${HYSTERIA_VERSION}"
echo
echo "服务器域名："
echo "  ${DOMAIN}"
echo
echo "服务器 IP："
echo "  ${SERVER_IP}"
echo
echo "端口："
echo "  ${SERVER_PORT}/UDP"
echo
echo "密码："
echo "  ${AUTH_PASSWORD}"
echo
echo "TLS SNI："
echo "  ${DOMAIN}"
echo
echo "TLS insecure："
echo "  false"
echo
echo "节点 URI："
echo
echo "hysteria2://${AUTH_PASSWORD}@${DOMAIN}:${SERVER_PORT}/?sni=${DOMAIN}&insecure=0"
echo
echo "================================================================"
echo
echo "服务管理："
echo
echo "查看状态："
echo "  systemctl status hysteria-server"
echo
echo "查看日志："
echo "  journalctl -u hysteria-server -f"
echo
echo "重启："
echo "  systemctl restart hysteria-server"
echo
echo "停止："
echo "  systemctl stop hysteria-server"
echo
echo "================================================================"
echo
echo "⚠️ 请保存好上面的密码。"
echo "⚠️ 请确认 Cloudflare DNS 中 ${DOMAIN} 已指向 ${SERVER_IP}。"
echo "⚠️ Cloudflare 代理请设置为 DNS Only（灰云），不要开启橙云。"
echo
echo "================================================================"
