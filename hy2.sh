
set -euo pipefail

# ---------- 默认配置 ----------
HYSTERIA_VERSION="v2.9.2"      # 2026-05-23 发布；建议定期到 release 页确认是否有更新
DEFAULT_PORT=22222
CERT_FILE="cert.pem"
KEY_FILE="key.pem"
PASSWORD_FILE="auth.pass"
SNI="www.bing.com"
ALPN="h3"
MEMORY_LIMIT="${GOMEMLIMIT:-70MiB}"   # Go 运行时软内存上限；100MB 总预算里给系统/其他进程留出余量
# ------------------------------

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "Hysteria2 极简部署脚本（Shell 版 · 低内存优化，目标 <100MB）"
echo "支持命令行端口参数，如：bash hysteria2.sh 443"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

# ---------- 获取端口 ----------
if [[ $# -ge 1 && -n "${1:-}" ]]; then
    SERVER_PORT="$1"
    echo "✅ 使用命令行指定端口: $SERVER_PORT"
else
    SERVER_PORT="${SERVER_PORT:-$DEFAULT_PORT}"
    echo "⚙️ 未提供端口参数，使用默认端口: $SERVER_PORT"
fi

# ---------- 密码：环境变量 > 已保存的密码 > 自动生成 ----------
if [[ -n "${AUTH_PASSWORD:-}" ]]; then
    echo "✅ 使用环境变量指定的密码"
elif [[ -f "$PASSWORD_FILE" ]]; then
    AUTH_PASSWORD=$(cat "$PASSWORD_FILE")
    echo "✅ 检测到已保存的密码（$PASSWORD_FILE），复用它以免重复运行时密码跟着变"
else
    AUTH_PASSWORD=$(openssl rand -hex 16)   # hex 而非 base64：避免 +/= 之类的字符把下面的 hysteria2:// 分享链接解析错乱
    echo "$AUTH_PASSWORD" > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
    echo "🔑 已自动生成随机密码并保存到 $PASSWORD_FILE（想固定密码可 export AUTH_PASSWORD=xxx 后再运行）"
fi

# ---------- 检测架构 ----------
arch_name() {
    local machine
    machine=$(uname -m | tr '[:upper:]' '[:lower:]')
    case "$machine" in
        x86_64|amd64)        echo "amd64" ;;
        aarch64|arm64)       echo "arm64" ;;
        armv7*)              echo "arm" ;;      # 尽力而为
        armv6*|armv5*|arm*)  echo "armv5" ;;     # 尽力而为，老旧/低端设备兜底
        i386|i686|x86)       echo "386" ;;
        mipsel|mipsle)       echo "mipsle" ;;
        riscv64)             echo "riscv64" ;;
        s390x)                echo "s390x" ;;
        *)                    echo "" ;;
    esac
}

ARCH="${BIN_ARCH_OVERRIDE:-$(arch_name)}"
if [ -z "$ARCH" ]; then
  echo "❌ 无法识别 CPU 架构: $(uname -m)"
  echo "   可手动指定，例如: BIN_ARCH_OVERRIDE=amd64 bash hysteria2.sh"
  exit 1
fi

BIN_NAME="hysteria-linux-${ARCH}"
BIN_PATH="./${BIN_NAME}"

# ---------- 校验和验证 ----------
verify_checksum() {
    local hash_url="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/hashes.txt"
    local hashes expected actual
    if ! hashes=$(curl -fsL --connect-timeout 10 --max-time 20 "$hash_url" 2>/dev/null); then
        echo "⚠️ 未能获取官方 hashes.txt，跳过完整性校验（不影响运行，建议之后手动核对一下）。"
        return
    fi
    expected=$(printf '%s\n' "$hashes" | grep -E "[[:space:]]${BIN_NAME}\$" | awk '{print $1}' | head -n1)
    if [[ -z "$expected" ]]; then
        echo "⚠️ hashes.txt 里没找到 ${BIN_NAME} 对应条目，跳过校验。"
        return
    fi
    actual=$(sha256sum "$BIN_PATH" | awk '{print $1}')
    if [[ "$expected" == "$actual" ]]; then
        echo "✅ SHA256 校验通过，二进制完整可信。"
    else
        echo "❌ SHA256 校验不匹配！期望 $expected，实际 $actual"
        echo "❌ 文件可能损坏或被篡改，已删除并退出。"
        rm -f "$BIN_PATH"
        exit 1
    fi
}

# ---------- 下载二进制 ----------
download_binary() {
    if [ -f "$BIN_PATH" ]; then
        echo "✅ 二进制已存在，跳过下载。"
        return
    fi
    local url="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${BIN_NAME}"
    echo "⏳ 下载: $url"
    if ! curl -fL --retry 3 --connect-timeout 30 -o "$BIN_PATH" "$url"; then
        echo "❌ 下载失败，请确认版本号/架构名正确，且网络能访问 GitHub。"
        rm -f "$BIN_PATH"
        exit 1
    fi
    chmod +x "$BIN_PATH"
    echo "✅ 下载完成并设置可执行: $BIN_PATH"
    verify_checksum
}

# ---------- 生成证书 ----------
ensure_cert() {
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        echo "✅ 发现证书，使用现有 cert/key。"
        return
    fi
    echo "🔑 未发现证书，使用 openssl 生成自签证书（prime256v1）..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${SNI}"
    chmod 600 "$KEY_FILE"
    echo "✅ 证书生成成功。"
}

# ---------- 写配置文件 ----------
write_config() {
cat > server.yaml <<EOF
listen: ":${SERVER_PORT}"
tls:
  cert: "$(pwd)/${CERT_FILE}"
  key: "$(pwd)/${KEY_FILE}"
  alpn:
    - "${ALPN}"
auth:
  type: "password"
  password: "${AUTH_PASSWORD}"
bandwidth:
  up: "200mbps"
  down: "200mbps"
quic:
  maxIdleTimeout: 10s
  maxIncomingStreams: 32
  initStreamReceiveWindow: 131072
  maxStreamReceiveWindow: 262144
  initConnReceiveWindow: 327680
  maxConnReceiveWindow: 655360
EOF
    echo "✅ 写入配置 server.yaml（端口=${SERVER_PORT}, SNI=${SNI}, ALPN=${ALPN}）。"
}

# ---------- 获取服务器 IP ----------
get_server_ip() {
    local ip
    ip=$(curl -fsL --max-time 8 https://api.ipify.org 2>/dev/null) \
        || ip=$(curl -fsL --max-time 8 https://ifconfig.me 2>/dev/null) \
        || ip="YOUR_SERVER_IP"
    echo "$ip"
}

# ---------- 生成可选的 systemd 单元文件（不会自动安装/启用） ----------
write_systemd_unit() {
    local workdir
    workdir="$(pwd)"
    cat > hysteria2.service <<EOF
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
Type=simple
WorkingDirectory=${workdir}
Environment=GOMEMLIMIT=${MEMORY_LIMIT}
ExecStart=${workdir}/${BIN_NAME} server -c ${workdir}/server.yaml
Restart=on-failure
RestartSec=5
MemoryMax=100M
MemoryHigh=90M
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    echo "📄 已生成 hysteria2.service（未自动安装）。想让它常驻、断开 SSH 也不掉线，可执行："
    echo "   sudo cp hysteria2.service /etc/systemd/system/ && sudo systemctl enable --now hysteria2"
}

# ---------- 打印连接信息 ----------
print_connection_info() {
    local IP="$1"
    echo "🎉 Hysteria2 部署成功！（低内存优化版）"
    echo "=========================================================================="
    echo "📋 服务器信息:"
    echo "   🌐 IP地址: $IP"
    echo "   🔌 端口: $SERVER_PORT"
    echo "   🔑 密码: $AUTH_PASSWORD  (已保存于 $PASSWORD_FILE)"
    echo "   🧠 GOMEMLIMIT: $MEMORY_LIMIT（可用 GOMEMLIMIT=xxx 环境变量覆盖）"
    echo ""
    echo "📱 节点链接（SNI=${SNI}, ALPN=${ALPN}, 跳过证书验证）:"
    echo "hysteria2://${AUTH_PASSWORD}@${IP}:${SERVER_PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#Hy2-Bing"
    echo ""
    echo "📄 客户端配置文件:"
    echo "server: ${IP}:${SERVER_PORT}"
    echo "auth: ${AUTH_PASSWORD}"
    echo "tls:"
    echo "  sni: ${SNI}"
    echo "  alpn: [\"${ALPN}\"]"
    echo "  insecure: true"
    echo "socks5:"
    echo "  listen: 127.0.0.1:1080"
    echo "http:"
    echo "  listen: 127.0.0.1:8080"
    echo "=========================================================================="
    echo "⚠️ 前台直接运行的进程会在 SSH 断开后被杀掉。"
    echo "   长期挂机请用 nohup/screen/tmux，或安装上面生成的 hysteria2.service。"
}

# ---------- 主逻辑 ----------
main() {
    download_binary
    ensure_cert
    write_config
    write_systemd_unit
    SERVER_IP=$(get_server_ip)
    print_connection_info "$SERVER_IP"
    export GOMEMLIMIT="$MEMORY_LIMIT"
    echo "🚀 启动 Hysteria2 服务器..."
    exec "$BIN_PATH" server -c server.yaml
}

main "$@"
