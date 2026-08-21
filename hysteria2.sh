#!/usr/bin/env bash
set -euo pipefail

# ---------- 脚本自身目录 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---------- 默认配置 ----------
DEFAULT_PORT=22222
CERT_FILE="cert.pem"
KEY_FILE="key.pem"
PASSWORD_FILE="auth.pass"
SNI="${SNI_OVERRIDE:-www.bing.com}"
ALPN="h3"
MEMORY_LIMIT="${GOMEMLIMIT:-70MiB}"
GITHUB_REPO="apernet/hysteria"
SERVICE_NAME="hysteria2"
RUN_USER="${RUN_USER:-hysteria2}"        # 默认专用低权限账号，而不是 root
RUN_GROUP="${RUN_GROUP:-$RUN_USER}"
LOG_LEVEL="${HYSTERIA_LOG_LEVEL:-warn}"  # debug/info/warn/error，默认 warn 减少日志量
AUTO_INSTALL="${AUTO_INSTALL:-1}"        # 1=自动安装并用 systemd 常驻启动；0=只生成文件，前台运行一次
# ------------------------------

log()  { echo "$@"; }
err()  { echo "$@" >&2; }

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "Hysteria2 一键部署脚本（自动最新稳定版 · SHA256 校验 · 自签证书 · pinSHA256 · systemd 加固）"
echo "用法: bash hysteria2.sh [端口]            部署/更新并启动"
echo "      bash hysteria2.sh diagnose          仅诊断当前部署为何连不通"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

MODE="deploy"
if [[ "${1:-}" == "diagnose" || "${1:-}" == "--diagnose" ]]; then
    MODE="diagnose"
    shift || true
fi

# ---------- 依赖检查 ----------
check_deps() {
    local missing=()
    for bin in curl openssl sha256sum grep sed awk uname ss; do
        command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
    done
    if [ "${#missing[@]}" -ne 0 ]; then
        err "❌ 缺少必要依赖: ${missing[*]}"
        err "   Debian/Ubuntu 可执行: sudo apt update && sudo apt install -y curl openssl coreutils grep sed gawk iproute2"
        exit 1
    fi
}
check_deps

# ---------- 获取端口并校验 ----------
parse_port() {
    local candidate="$1"
    if [[ ! "$candidate" =~ ^[0-9]+$ ]] || [ "$candidate" -lt 1 ] || [ "$candidate" -gt 65535 ]; then
        err "❌ 非法端口: $candidate（必须是 1-65535 之间的整数）"
        exit 1
    fi
}

if [[ -f server.yaml && $# -eq 0 ]]; then
    # 复用已有部署的端口，避免 diagnose/重新运行时端口对不上
    EXISTING_PORT=$(grep -E '^listen:' server.yaml | sed -E 's/^listen:\s*":?([0-9]+)".*/\1/' || true)
fi

if [[ $# -ge 1 && -n "${1:-}" ]]; then
    SERVER_PORT="$1"
    parse_port "$SERVER_PORT"
    log "✅ 使用命令行指定端口: $SERVER_PORT"
elif [[ -n "${EXISTING_PORT:-}" ]]; then
    SERVER_PORT="$EXISTING_PORT"
    parse_port "$SERVER_PORT"
    log "♻️  复用已有配置里的端口: $SERVER_PORT"
else
    SERVER_PORT="${SERVER_PORT:-$DEFAULT_PORT}"
    parse_port "$SERVER_PORT"
    log "⚙️ 未提供端口参数，使用默认端口: $SERVER_PORT"
fi

# ---------- 检测架构（diagnose 模式也需要，用于确认二进制存在） ----------
arch_name() {
    local machine
    machine=$(uname -m | tr '[:upper:]' '[:lower:]')
    case "$machine" in
        x86_64|amd64)        echo "amd64" ;;
        aarch64|arm64)       echo "arm64" ;;
        armv7*)              echo "arm" ;;
        armv6*|armv5*|arm*)  echo "armv5" ;;
        i386|i686|x86)       echo "386" ;;
        mipsel|mipsle)       echo "mipsle" ;;
        riscv64)             echo "riscv64" ;;
        s390x)                echo "s390x" ;;
        *)                    echo "" ;;
    esac
}
ARCH="${BIN_ARCH_OVERRIDE:-$(arch_name)}"
if [ -z "$ARCH" ]; then
  err "❌ 无法识别 CPU 架构: $(uname -m)"
  err "   可手动指定，例如: BIN_ARCH_OVERRIDE=amd64 bash hysteria2.sh"
  exit 1
fi
BIN_NAME="hysteria-linux-${ARCH}"
BIN_PATH="${SCRIPT_DIR}/${BIN_NAME}"

# ============================================================
#  诊断模式：不改动任何东西，只检查“为什么连不上”
# ============================================================
diagnose() {
    echo "==================== 连通性诊断 ===================="
    local fail=0

    # 1. systemd 服务状态
    if systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}.service"; then
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            echo "✅ systemd 服务 ${SERVICE_NAME} 正在运行"
        else
            echo "❌ systemd 服务 ${SERVICE_NAME} 未运行（这是最常见的“连不通”原因）"
            echo "   最近日志："
            journalctl -u "$SERVICE_NAME" -n 20 --no-pager 2>/dev/null | sed 's/^/     /'
            fail=1
        fi
    else
        echo "❌ 尚未安装 ${SERVICE_NAME}.service —— 说明你之前很可能是前台直接运行脚本，"
        echo "   一旦 SSH 断开或终端关闭，进程就被杀掉了，这是“连接不通”最常见的原因。"
        fail=1
    fi

    # 2. 端口是否真的在监听（UDP）
    if [[ -f server.yaml ]]; then
        local port
        port=$(grep -E '^listen:' server.yaml | sed -E 's/^listen:\s*":?([0-9]+)".*/\1/')
        if ss -lun 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${port}\$"; then
            echo "✅ 本机 UDP ${port} 端口正在监听"
        else
            echo "❌ 本机没有任何进程在监听 UDP ${port}，服务实际上没跑起来"
            fail=1
        fi
    else
        echo "⚠️ 未找到 server.yaml，可能还没部署过"
        fail=1
    fi

    # 3. 本机防火墙
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        if ufw status 2>/dev/null | grep -q "${SERVER_PORT}/udp"; then
            echo "✅ ufw 已放行 ${SERVER_PORT}/udp"
        else
            echo "❌ ufw 已启用，但没有放行 ${SERVER_PORT}/udp"
            echo "   修复: sudo ufw allow ${SERVER_PORT}/udp"
            fail=1
        fi
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        if firewall-cmd --list-ports 2>/dev/null | grep -q "${SERVER_PORT}/udp"; then
            echo "✅ firewalld 已放行 ${SERVER_PORT}/udp"
        else
            echo "❌ firewalld 正在运行，但没有放行 ${SERVER_PORT}/udp"
            echo "   修复: sudo firewall-cmd --add-port=${SERVER_PORT}/udp --permanent && sudo firewall-cmd --reload"
            fail=1
        fi
    else
        echo "ℹ️ 未检测到 ufw/firewalld 处于启用状态（可能用的是裸 iptables，或没有本机防火墙）"
    fi

    # 4. 证书有效期
    if [[ -f "$CERT_FILE" ]]; then
        if openssl x509 -in "$CERT_FILE" -noout -checkend 86400 >/dev/null 2>&1; then
            echo "✅ 证书未过期（至少还有 1 天有效期）"
        else
            echo "❌ 证书已过期或即将过期，客户端 TLS 握手会失败"
            fail=1
        fi
    fi

    # 5. 出网连通性 / DNS
    if curl -fsL --max-time 5 https://api.ipify.org >/dev/null 2>&1; then
        echo "✅ 服务器出网正常（能访问外部 HTTPS）"
    else
        echo "⚠️ 服务器出网异常或 DNS 解析失败，无法访问外部服务（不影响客户端直连，但会影响自动更新/IP探测）"
    fi

    echo "======================================================"
    echo "⚠️ 以上只能检查“服务端本身”。如果本机一切正常但客户端仍连不上，"
    echo "   99% 的剩余原因是：云厂商安全组 / 控制台防火墙没有放行 UDP ${SERVER_PORT}端口"
    echo "   （这一步在 VPS 内部完全看不出来，必须去云控制台手动检查）。"
    if [[ $fail -eq 0 ]]; then
        echo "🎉 本机侧检查全部通过。"
    fi
}

if [[ "$MODE" == "diagnose" ]]; then
    diagnose
    exit 0
fi

# ---------- 密码 ----------
sanitize_password() {
    if [[ "$1" == *'"'* || "$1" == *'\'* ]]; then
        err "❌ AUTH_PASSWORD 中包含引号或反斜杠，可能破坏配置文件格式，请更换密码后重试。"
        exit 1
    fi
}

if [[ -n "${AUTH_PASSWORD:-}" ]]; then
    sanitize_password "$AUTH_PASSWORD"
    log "✅ 使用环境变量指定的密码"
elif [[ -f "$PASSWORD_FILE" ]]; then
    AUTH_PASSWORD=$(tr -d '\r\n' < "$PASSWORD_FILE")
    log "✅ 检测到已保存的密码($PASSWORD_FILE)，复用它以免重复运行时密码跟着变"
else
    AUTH_PASSWORD=$(openssl rand -hex 16)
    echo "$AUTH_PASSWORD" > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
    log "🔑 已自动生成随机密码并保存到 $PASSWORD_FILE"
fi

# ---------- 自动获取最新稳定版本号 ----------
detect_latest_version() {
    err "🔍 正在查询 Hysteria 官方最新稳定版本..."
    local api_url="https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=30"
    local json version
    if ! json=$(curl -fsSL --connect-timeout 10 --max-time 20 "$api_url" 2>/dev/null); then
        err "❌ 无法访问 GitHub API 获取版本信息，已终止（不回退到旧版本）。"
        exit 1
    fi
    version=$(printf '%s\n' "$json" | awk '
        /"tag_name":/   { gsub(/[",]/,""); split($0,a,": "); tag=a[2] }
        /"draft":/      { gsub(/[",]/,""); split($0,a,": "); draft=a[2] }
        /"prerelease":/ { gsub(/[",]/,""); split($0,a,": "); pre=a[2]
            if (tag ~ /^app\/v[0-9]+\.[0-9]+\.[0-9]+$/ && draft=="false" && pre=="false") {
                print tag; exit
            }
        }
    ')
    if [[ -z "$version" ]]; then
        err "❌ 未能获取到正式（非 beta/RC/预发布）版本号，已终止。"
        exit 1
    fi
    printf '%s' "$version"
}

HYSTERIA_VERSION_TAG="$(detect_latest_version)"
HYSTERIA_VERSION="${HYSTERIA_VERSION_TAG#app/}"
log "✅ 最新稳定版本: ${HYSTERIA_VERSION}（release tag: ${HYSTERIA_VERSION_TAG}）"

# ---------- 校验和验证 ----------
verify_checksum() {
    local hash_url="https://github.com/apernet/hysteria/releases/download/${HYSTERIA_VERSION_TAG}/hashes.txt"
    local hashes expected actual
    if ! hashes=$(curl -fsL --connect-timeout 10 --max-time 20 "$hash_url" 2>/dev/null); then
        err "⚠️ 未能获取官方 hashes.txt(${HYSTERIA_VERSION_TAG})，无法验证二进制完整性。"
        return 1
    fi
    expected=$(printf '%s\n' "$hashes" | awk -v bin="$BIN_NAME" '
        { n = split($NF, parts, "/"); if (parts[n] == bin) { print $1; exit } }
    ' || true)
    if [[ -z "$expected" ]]; then
        err "⚠️ hashes.txt(${HYSTERIA_VERSION_TAG})里没有 ${BIN_NAME} 对应条目，无法验证。"
        return 1
    fi
    actual=$(sha256sum "$BIN_PATH" | awk '{print $1}')
    if [[ "$expected" == "$actual" ]]; then
        log "✅ SHA256 校验通过，二进制完整可信。"
        return 0
    else
        err "⚠️ SHA256 不匹配（期望 $expected，实际 $actual）。"
        return 1
    fi
}

# ---------- 下载二进制 ----------
download_binary() {
    if [ -f "$BIN_PATH" ]; then
        log "🔍 发现已存在的二进制，先校验完整性（对照当前最新版 ${HYSTERIA_VERSION_TAG}）..."
        if verify_checksum; then
            log "✅ 校验通过，复用已存在的二进制，跳过下载。"
            return
        fi
        log "ℹ️ 该文件可能是旧版本、已损坏或被篡改，将重新下载最新版本覆盖它。"
        rm -f "$BIN_PATH"
    fi
    local url="https://github.com/apernet/hysteria/releases/download/${HYSTERIA_VERSION_TAG}/${BIN_NAME}"
    log "⏳ 下载: $url"
    if ! curl -fL --retry 3 --connect-timeout 30 -o "$BIN_PATH" "$url"; then
        err "❌ 下载失败，请确认版本号/架构名正确，且网络能访问 GitHub。"
        rm -f "$BIN_PATH"
        exit 1
    fi
    chmod +x "$BIN_PATH"
    log "✅ 下载完成并设置可执行: $BIN_PATH"
    if ! verify_checksum; then
        err "❌ 文件可能损坏或被篡改，已删除并终止。"
        rm -f "$BIN_PATH"
        exit 1
    fi
}

# ---------- 生成自签证书 ----------
ensure_cert() {
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        log "✅ 发现完整证书对，复用现有 cert/key（pinSHA256 保持不变）。"
        return
    fi
    if [ -f "$CERT_FILE" ] || [ -f "$KEY_FILE" ]; then
        err "❌ 检测到 $CERT_FILE 与 $KEY_FILE 只存在其中一个，证书对不完整，已终止。"
        exit 1
    fi
    log "🔑 未发现证书，使用 openssl 生成自签证书（prime256v1，CN=${SNI}）..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${SNI}"
    chmod 600 "$KEY_FILE"
    log "✅ 证书生成成功。"
}

compute_pin_sha256() {
    local fp
    fp=$(openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 2>/dev/null | sed -E 's/^.*Fingerprint=//')
    if [[ -z "$fp" ]]; then
        err "❌ 无法计算证书 SHA256 指纹，已终止。"
        exit 1
    fi
    printf '%s' "$fp"
}

# ---------- 创建专用运行账号（权限隔离核心） ----------
ensure_run_user() {
    if ! id "$RUN_USER" >/dev/null 2>&1; then
        if [[ $EUID -ne 0 ]]; then
            err "⚠️ 当前非 root，无法创建系统账号 ${RUN_USER}，systemd 单元将退回以当前用户身份的说明运行（需你手动处理）。"
            return
        fi
        log "👤 创建专用系统账号 ${RUN_USER}（无登录 shell、无 home，仅用于运行 Hysteria2）..."
        useradd --system --no-create-home --shell /usr/sbin/nologin "$RUN_USER" 2>/dev/null \
            || useradd --system --no-create-home --shell /sbin/nologin "$RUN_USER"
    else
        log "✅ 系统账号 ${RUN_USER} 已存在，复用。"
    fi
}

# ---------- 收紧文件权限归属，使专用账号只能读它需要的东西 ----------
lock_down_permissions() {
    if [[ $EUID -eq 0 ]] && id "$RUN_USER" >/dev/null 2>&1; then
        chown "${RUN_USER}:${RUN_GROUP}" "$KEY_FILE" "$CERT_FILE" server.yaml "$BIN_PATH" 2>/dev/null || true
        chmod 600 "$KEY_FILE" server.yaml
        chmod 644 "$CERT_FILE"
        chmod 750 "$BIN_PATH"
        chmod 700 "$SCRIPT_DIR"
        log "🔒 已将证书/密钥/配置/二进制的属主收紧为 ${RUN_USER}，其他账号（含普通用户）读不到。"
    fi
}

# ---------- 写配置文件 ----------
write_config() {
    local bw_block=""
    if [[ -n "${SERVER_BW_UP:-}" && -n "${SERVER_BW_DOWN:-}" ]]; then
        bw_block="bandwidth:
  up: \"${SERVER_BW_UP}\"
  down: \"${SERVER_BW_DOWN}\""
    fi

    cat > server.yaml <<EOF
listen: ":${SERVER_PORT}"
tls:
  cert: "${SCRIPT_DIR}/${CERT_FILE}"
  key: "${SCRIPT_DIR}/${KEY_FILE}"
  alpn:
    - "${ALPN}"
auth:
  type: "password"
  password: "${AUTH_PASSWORD}"
${bw_block}
quic:
  maxIdleTimeout: 10s
  maxIncomingStreams: 32
  initStreamReceiveWindow: 131072
  maxStreamReceiveWindow: 262144
  initConnReceiveWindow: 327680
  maxConnReceiveWindow: 655360
EOF
    chmod 600 server.yaml

    if ! grep -q '^listen:' server.yaml || ! grep -q '^auth:' server.yaml; then
        err "❌ 配置文件生成异常（缺少关键字段），已终止，不会启动服务。"
        exit 1
    fi
    log "✅ 写入配置 server.yaml（端口=${SERVER_PORT}, SNI=${SNI}[仅 TLS SNI], ALPN=${ALPN}）。"
}

get_server_ip() {
    local ip local_ip
    ip=$(curl -fsL --max-time 8 https://api.ipify.org 2>/dev/null) \
        || ip=$(curl -fsL --max-time 8 https://ifconfig.me 2>/dev/null) \
        || ip=""
    if [[ -z "$ip" ]]; then
        local_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "$local_ip" ]]; then
            err "⚠️ 无法访问外部 IP 探测服务，回退使用本机网卡地址 $local_ip（NAT 环境下可能不是公网地址）。"
            ip="$local_ip"
        else
            ip="YOUR_SERVER_IP"
        fi
    fi
    echo "$ip"
}

# ---------- 生成 ExecStartPre 用的启动前自检脚本 ----------
# 任何一项不过直接 exit 非零 -> systemd 会 fail-fast 并把原因写进 journal，
# 而不是让主进程带着坏配置起来又秒退、日志里只有一句语焉不详的报错。
write_preflight_script() {
    cat > "${SCRIPT_DIR}/hysteria2-preflight.sh" <<'PFEOF'
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

fail() { echo "[preflight] ❌ $*" >&2; exit 1; }
ok()   { echo "[preflight] ✅ $*"; }

# 1. 配置文件存在且关键字段齐全
[[ -f server.yaml ]] || fail "server.yaml 不存在"
grep -q '^listen:' server.yaml || fail "server.yaml 缺少 listen 字段"
grep -q '^auth:'   server.yaml || fail "server.yaml 缺少 auth 字段"
ok "配置文件检查通过"

# 2. 证书存在、可读、未过期
CERT=$(grep -E '^\s*cert:' server.yaml | sed -E 's/.*cert:\s*"?([^"]+)"?.*/\1/')
KEY=$(grep -E '^\s*key:'  server.yaml | sed -E 's/.*key:\s*"?([^"]+)"?.*/\1/')
[[ -r "$CERT" ]] || fail "证书文件不存在或不可读: $CERT"
[[ -r "$KEY"  ]] || fail "私钥文件不存在或不可读: $KEY"
openssl x509 -in "$CERT" -noout -checkend 0 >/dev/null 2>&1 || fail "证书已过期: $CERT"
ok "证书检查通过（存在、可读、未过期）"

# 3. 端口未被其他进程占用
PORT=$(grep -E '^listen:' server.yaml | sed -E 's/^listen:\s*":?([0-9]+)".*/\1/')
if ss -lun 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${PORT}\$"; then
    fail "UDP 端口 ${PORT} 已被占用（可能是上一次实例未退出，或端口冲突）"
fi
ok "端口 ${PORT} 空闲"

# 4. DNS / 出网连通性（尽力而为，失败只警告不阻断启动，避免断网环境下无法自愈重启）
if ! getent hosts github.com >/dev/null 2>&1 && ! getent hosts 1.1.1.1 >/dev/null 2>&1; then
    echo "[preflight] ⚠️ DNS 解析异常，可能影响后续自动更新（不影响本次启动）" >&2
fi

ok "全部启动前检查通过"
PFEOF
    chmod +x "${SCRIPT_DIR}/hysteria2-preflight.sh"
    if [[ $EUID -eq 0 ]] && id "$RUN_USER" >/dev/null 2>&1; then
        chown "${RUN_USER}:${RUN_GROUP}" "${SCRIPT_DIR}/hysteria2-preflight.sh"
    fi
    log "✅ 已生成启动前自检脚本 hysteria2-preflight.sh"
}

# ---------- 生成加固版 systemd 单元 ----------
write_systemd_unit() {
    local user_block="User=${RUN_USER}
Group=${RUN_GROUP}"

    # <1024 的特权端口需要单独授予 CAP_NET_BIND_SERVICE，否则非 root 账号 bind 会失败
    local cap_line=""
    if [[ "$SERVER_PORT" -lt 1024 ]]; then
        cap_line="AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE"
    else
        cap_line="CapabilityBoundingSet="
    fi

    cat > "${SCRIPT_DIR}/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Hysteria2 Server
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
Type=simple
WorkingDirectory=${SCRIPT_DIR}
${user_block}
Environment=GOMEMLIMIT=${MEMORY_LIMIT}
Environment=HYSTERIA_LOG_LEVEL=${LOG_LEVEL}
ExecStartPre=${SCRIPT_DIR}/hysteria2-preflight.sh
ExecStart=${BIN_PATH} server -c ${SCRIPT_DIR}/server.yaml

# ---- 重启策略 ----
Restart=on-failure
RestartSec=5

# ---- 资源限制 ----
MemoryMax=100M
MemoryHigh=90M
TasksMax=64

# ---- 权限最小化 / 提权防护 ----
${cap_line}
NoNewPrivileges=true
LockPersonality=true
RestrictSUIDSGID=true
RestrictRealtime=true
RemoveIPC=true

# ---- 文件系统隔离 ----
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectClock=true
ProtectHostname=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ReadOnlyPaths=${SCRIPT_DIR}
UMask=0077

# ---- 网络能力范围 ----
# 只允许 IPv4/IPv6 socket（挡掉 AF_NETLINK/AF_PACKET 等异常能力）；
# 不设 IPAddressDeny/Allow，因为 Hysteria2 本身是代理，需要能连接任意出网目标，
# 收紧这里会直接打断代理功能，不是这个服务该加的限制。
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=true

# ---- 系统调用白名单 ----
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @mount @debug @cpu-emulation @obsolete @swap @reboot @raw-io
SystemCallErrorNumber=EPERM
SystemCallArchitectures=native

# ---- 日志：交给 journald，限速防止刷屏把磁盘写满 ----
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}
LogRateLimitIntervalSec=30s
LogRateLimitBurst=1000

[Install]
WantedBy=multi-user.target
EOF
    log "📄 已生成加固版 ${SERVICE_NAME}.service"
    log "   说明：MemoryDenyWriteExecute 未启用（部分 Go 版本的运行时在个别内核上与其冲突导致启动失败，"
    log "   如果你的系统能兼容，可以在 [Service] 段里手动加一行 MemoryDenyWriteExecute=true 进一步加固）。"
}

print_connection_info() {
    local IP="$1"
    echo "🎉 Hysteria2 部署成功！"
    echo "=========================================================================="
    echo "📋 服务器信息:"
    echo "   🌐 IP地址: $IP"
    echo "   🔌 端口(UDP): $SERVER_PORT"
    echo "   🔑 密码: $AUTH_PASSWORD  (已保存于 $PASSWORD_FILE)"
    echo "   🔏 证书 pinSHA256: $PIN_SHA256"
    echo "   👤 运行账号: $RUN_USER（非 root，权限已隔离）"
    echo ""
    echo "📱 节点链接（hysteria2 官方客户端 / NekoBox 等支持 pinSHA256 的客户端用这个）:"
    echo "hysteria2://${AUTH_PASSWORD}@${IP}:${SERVER_PORT}?sni=${SNI}&alpn=${ALPN}&pinSHA256=${PIN_SHA256}#Hy2"
    echo ""
    echo "📱 sing-box outbound 配置（自签证书，必须 insecure:true，直接复制进 config.json）:"
    cat <<SINGBOX
{
  "type": "hysteria2",
  "tag": "hy2-out",
  "server": "${IP}",
  "server_port": ${SERVER_PORT},
  "password": "${AUTH_PASSWORD}",
  "tls": {
    "enabled": true,
    "server_name": "${SNI}",
    "insecure": true,
    "alpn": ["${ALPN}"]
  }
}
SINGBOX
    echo ""
    echo "   ⚠️ sing-box 不支持 pinSHA256 证书指纹校验，只能靠 insecure:true 跳过证书链校验，"
    echo "   这不是降低安全性的额外妥协——自签证书场景下 sing-box 本来就只能这样连，正常现象。"
    echo "=========================================================================="
    echo "⚠️ Hysteria2 使用 UDP/QUIC 协议，请务必确认云厂商安全组已放行 UDP ${SERVER_PORT}"
    echo "   （本机侧一切正常也可能因为云控制台安全组没放行而连不通，这一步只能去控制台手动查）。"
}

# ---------- 启动后自检：真正确认服务活着、端口在听，而不是“exec 了就当成功” ----------
post_start_healthcheck() {
    local tries=10
    log "🔎 正在校验服务是否真正启动成功..."
    for ((i=1; i<=tries; i++)); do
        if systemctl is-active --quiet "$SERVICE_NAME" \
           && ss -lun 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${SERVER_PORT}\$"; then
            log "✅ 服务运行中，且 UDP ${SERVER_PORT} 正在监听。"
            return 0
        fi
        sleep 1
    done
    err "❌ 服务启动后 ${tries} 秒内仍未监听端口，判定为启动失败。最近日志："
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager 2>/dev/null | sed 's/^/   /' >&2
    return 1
}

main() {
    download_binary
    ensure_cert
    PIN_SHA256="$(compute_pin_sha256)"
    write_config
    ensure_run_user
    write_preflight_script
    write_systemd_unit
    lock_down_permissions

    SERVER_IP=$(get_server_ip)

    if [[ "$AUTO_INSTALL" == "1" && $EUID -eq 0 ]]; then
        log "🚀 安装为 systemd 服务并常驻启动（AUTO_INSTALL=1，SSH 断开也不会掉线）..."
        cp -f "${SCRIPT_DIR}/${SERVICE_NAME}.service" "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload
        systemctl enable --now "$SERVICE_NAME"
        if post_start_healthcheck; then
            print_connection_info "$SERVER_IP"
        else
            err "部署未成功，请查看上面的日志定位原因，或运行: bash $0 diagnose"
            exit 1
        fi
    else
        if [[ $EUID -ne 0 ]]; then
            err "ℹ️ 当前非 root，无法自动安装 systemd 服务。已生成所有文件，请自行执行："
            err "   sudo cp ${SERVICE_NAME}.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now ${SERVICE_NAME}"
        else
            log "ℹ️ AUTO_INSTALL=0，仅生成文件，不自动安装/启动。"
        fi
        print_connection_info "$SERVER_IP"
    fi
}

main "$@"
