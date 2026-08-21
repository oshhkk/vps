#!/usr/bin/env bash
set -euo pipefail

# ---------- 脚本自身目录(无论从哪里执行,都统一以脚本所在目录为工作目录) ----------
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
RUN_USER="${RUN_USER:-hysteria2}"
RUN_GROUP="${RUN_GROUP:-$RUN_USER}"
UPDATE_ONLY=0
# ------------------------------

# 支持 `bash hysteria2.sh --update-only [端口]`:只做"下载+校验+写配置"不动 systemd/防火墙/不启动,
# 供 hysteria2-update.sh 复用同一套下载/校验逻辑,避免两处代码维护两份。
if [[ "${1:-}" == "--update-only" ]]; then
    UPDATE_ONLY=1
    shift
fi

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "Hysteria2 一键部署脚本(自动最新稳定版 · SHA256 校验 · 自签证书 · pinSHA256)"
echo "支持命令行端口参数,如:bash hysteria2.sh 443"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

# ---------- 依赖检查 ----------
check_deps() {
    local missing=()
    for bin in curl openssl sha256sum grep sed awk uname; do
        command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
    done
    if [ "${#missing[@]}" -ne 0 ]; then
        echo "❌ 缺少必要依赖: ${missing[*]}"
        echo "   Debian/Ubuntu 可执行: sudo apt update && sudo apt install -y curl openssl coreutils grep sed gawk"
        exit 1
    fi
}
check_deps

# ---------- 获取端口并校验 ----------
parse_port() {
    local candidate="$1"
    if [[ ! "$candidate" =~ ^[0-9]+$ ]] || [ "$candidate" -lt 1 ] || [ "$candidate" -gt 65535 ]; then
        echo "❌ 非法端口: $candidate(必须是 1-65535 之间的整数)"
        exit 1
    fi
}

if [[ $# -ge 1 && -n "${1:-}" ]]; then
    SERVER_PORT="$1"
    parse_port "$SERVER_PORT"
    echo "✅ 使用命令行指定端口: $SERVER_PORT"
elif [[ -f server.yaml ]]; then
    # --update-only 场景下没人传端口,优先复用已有配置里的端口,而不是回退到默认端口
    SERVER_PORT="$(grep '^listen:' server.yaml | grep -oE '[0-9]+' | head -n1 || true)"
    SERVER_PORT="${SERVER_PORT:-${SERVER_PORT_ENV:-$DEFAULT_PORT}}"
    parse_port "$SERVER_PORT"
    echo "⚙️ 复用已有配置中的端口: $SERVER_PORT"
else
    SERVER_PORT="${SERVER_PORT:-$DEFAULT_PORT}"
    parse_port "$SERVER_PORT"
    echo "⚙️ 未提供端口参数,使用默认端口: $SERVER_PORT"
fi

# ---------- 密码:环境变量 > 已保存的密码 > 自动生成(脚本开箱即用,环境变量只是可选覆盖) ----------
sanitize_password() {
    if [[ "$1" == *'"'* || "$1" == *'\'* ]]; then
        echo "❌ AUTH_PASSWORD 中包含引号或反斜杠,可能破坏配置文件格式,请更换密码后重试。"
        exit 1
    fi
}

if [[ -n "${AUTH_PASSWORD:-}" ]]; then
    sanitize_password "$AUTH_PASSWORD"
    echo "✅ 使用环境变量指定的密码"
elif [[ -f "$PASSWORD_FILE" ]]; then
    AUTH_PASSWORD=$(tr -d '\r\n' < "$PASSWORD_FILE")
    echo "✅ 检测到已保存的密码($PASSWORD_FILE),复用它以免重复运行时密码跟着变"
else
    AUTH_PASSWORD=$(openssl rand -hex 16)
    echo "$AUTH_PASSWORD" > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
    echo "🔑 已自动生成随机密码并保存到 $PASSWORD_FILE(想固定密码可 export AUTH_PASSWORD=xxx 后再运行)"
fi

# ---------- 检测架构 ----------
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
  echo "❌ 无法识别 CPU 架构: $(uname -m)"
  echo "   可手动指定,例如: BIN_ARCH_OVERRIDE=amd64 bash hysteria2.sh"
  exit 1
fi

# ---------- 自动获取最新稳定版本号(排除 beta/RC/预发布,失败直接退出不回退旧版本) ----------
detect_latest_version() {
    echo "🔍 正在查询 Hysteria 官方最新稳定版本..." >&2
    local api_url="https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=30"
    local json version
    if ! json=$(curl -fsSL --connect-timeout 10 --max-time 20 "$api_url" 2>/dev/null); then
        echo "❌ 无法访问 GitHub API 获取版本信息,已终止(不回退到旧版本)。" >&2
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
        echo "❌ 未能获取到正式(非 beta/RC/预发布)版本号,已终止。" >&2
        exit 1
    fi
    printf '%s' "$version"
}

HYSTERIA_VERSION_TAG="$(detect_latest_version)"
HYSTERIA_VERSION="${HYSTERIA_VERSION_TAG#app/}"
echo "✅ 最新稳定版本: ${HYSTERIA_VERSION}(release tag: ${HYSTERIA_VERSION_TAG})"

BIN_NAME="hysteria-linux-${ARCH}"
BIN_PATH="./${BIN_NAME}"

# ---------- 校验和验证 ----------
verify_checksum() {
    local hash_url="https://github.com/apernet/hysteria/releases/download/${HYSTERIA_VERSION_TAG}/hashes.txt"
    local hashes expected actual
    if ! hashes=$(curl -fsL --connect-timeout 10 --max-time 20 "$hash_url" 2>/dev/null); then
        echo "⚠️ 未能获取官方 hashes.txt(${HYSTERIA_VERSION_TAG}),无法验证二进制完整性。"
        return 1
    fi
    expected=$(printf '%s\n' "$hashes" | awk -v bin="$BIN_NAME" '
        { n = split($NF, parts, "/"); if (parts[n] == bin) { print $1; exit } }
    ' || true)
    if [[ -z "$expected" ]]; then
        echo "⚠️ hashes.txt(${HYSTERIA_VERSION_TAG})里没有 ${BIN_NAME} 对应条目,无法验证。"
        return 1
    fi
    actual=$(sha256sum "$BIN_PATH" | awk '{print $1}')
    if [[ "$expected" == "$actual" ]]; then
        echo "✅ SHA256 校验通过,二进制完整可信。"
        return 0
    else
        echo "⚠️ SHA256 不匹配(期望 $expected,实际 $actual),与当前最新版(${HYSTERIA_VERSION_TAG})不一致。"
        return 1
    fi
}

# ---------- 下载二进制 ----------
download_binary() {
    if [ -f "$BIN_PATH" ]; then
        echo "🔍 发现已存在的二进制 $BIN_PATH,先校验完整性(对照当前最新版 ${HYSTERIA_VERSION_TAG})..."
        if verify_checksum; then
            echo "✅ 校验通过,复用已存在的二进制,跳过下载。"
            return
        fi
        echo "ℹ️ 该文件可能是旧版本、已损坏或被篡改,将重新下载最新版本覆盖它。"
        rm -f "$BIN_PATH"
    fi
    local url="https://github.com/apernet/hysteria/releases/download/${HYSTERIA_VERSION_TAG}/${BIN_NAME}"
    echo "⏳ 下载: $url"
    if ! curl -fL --retry 3 --connect-timeout 30 -o "$BIN_PATH" "$url"; then
        echo "❌ 下载失败,请确认版本号/架构名正确,且网络能访问 GitHub。"
        rm -f "$BIN_PATH"
        exit 1
    fi
    chmod +x "$BIN_PATH"
    echo "✅ 下载完成并设置可执行: $BIN_PATH"
    if ! verify_checksum; then
        echo "❌ 文件可能损坏或被篡改(或校验信息不可获取),已删除并终止(不允许启动未验证的二进制)。"
        rm -f "$BIN_PATH"
        exit 1
    fi
}

# ---------- 生成自签证书(cert/key 必须成对管理) ----------
ensure_cert() {
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        echo "✅ 发现完整证书对,复用现有 cert/key(不重新生成,pinSHA256 保持不变)。"
        return
    fi
    if [ -f "$CERT_FILE" ] || [ -f "$KEY_FILE" ]; then
        echo "❌ 检测到 $CERT_FILE 与 $KEY_FILE 只存在其中一个,证书对不完整。"
        echo "   为避免覆盖/误删已有文件,已终止。请手动确认后删除残留的单个文件再重新运行。"
        exit 1
    fi
    echo "🔑 未发现证书,使用 openssl 生成自签证书(prime256v1,CN=${SNI})..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${SNI}"
    chmod 600 "$KEY_FILE"
    echo "✅ 证书生成成功。"
}

# ---------- 计算证书 pinSHA256 指纹 ----------
compute_pin_sha256() {
    local fp
    fp=$(openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 2>/dev/null | sed -E 's/^.*Fingerprint=//')
    if [[ -z "$fp" ]]; then
        echo "❌ 无法计算证书 SHA256 指纹,已终止。" >&2
        exit 1
    fi
    printf '%s' "$fp"
}

# ---------- 写配置文件 ----------
write_config() {
    local bw_block=""
    if [[ -n "${SERVER_BW_UP:-}" && -n "${SERVER_BW_DOWN:-}" ]]; then
        bw_block="bandwidth:
  up: \"${SERVER_BW_UP}\"
  down: \"${SERVER_BW_DOWN}\""
        echo "ℹ️ 已按 SERVER_BW_UP/SERVER_BW_DOWN 写入 bandwidth 段。"
    else
        echo "ℹ️ 未设置 SERVER_BW_UP/SERVER_BW_DOWN,不写入 bandwidth 段,交给 Hysteria2 自身带宽探测处理。"
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
        echo "❌ 配置文件生成异常(缺少关键字段),已终止,不会启动服务。"
        exit 1
    fi
    echo "✅ 写入配置 server.yaml(端口=${SERVER_PORT}, SNI=${SNI}[仅 TLS SNI], ALPN=${ALPN})。"
}

# ---------- 获取服务器公网 IP ----------
get_server_ip() {
    local ip local_ip
    ip=$(curl -fsL --max-time 8 https://api.ipify.org 2>/dev/null) \
        || ip=$(curl -fsL --max-time 8 https://ifconfig.me 2>/dev/null) \
        || ip=""
    if [[ -z "$ip" ]]; then
        local_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "$local_ip" ]]; then
            echo "⚠️ 无法访问外部 IP 探测服务,回退使用本机网卡地址 $local_ip" >&2
            echo "⚠️ 如果服务器在 NAT/内网环境,这可能不是公网可达地址,请手动核实。" >&2
            ip="$local_ip"
        else
            ip="YOUR_SERVER_IP"
        fi
    fi
    echo "$ip"
}

# ---------- 【连通性关键项 1】自动放行本机防火墙 UDP 端口 ----------
# Hysteria2 是 UDP/QUIC 协议,"连接不通"最常见原因就是:
#   本机防火墙没放 UDP、或云厂商安全组没放 UDP、或两者都没放。
# 本机这层能自动做,云厂商那层脚本够不到,只能强提示。
open_firewall_port() {
    local port="$1"
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "⚠️ 当前非 root 运行,跳过自动防火墙配置。请自行确认 UDP ${port} 已放行(或用 sudo 重跑本脚本)。"
        return
    fi
    echo "🔧 检测并尝试放行本机防火墙 UDP ${port} 端口..."
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
        ufw allow "${port}/udp" >/dev/null 2>&1 \
            && echo "✅ ufw 已放行 UDP ${port}" \
            || echo "⚠️ ufw 放行失败,请手动执行: ufw allow ${port}/udp"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${port}/udp" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 \
            && echo "✅ firewalld 已放行 UDP ${port}" \
            || echo "⚠️ firewalld 放行失败,请手动执行: firewall-cmd --permanent --add-port=${port}/udp && firewall-cmd --reload"
    elif command -v iptables >/dev/null 2>&1; then
        if ! iptables -C INPUT -p udp --dport "${port}" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT -p udp --dport "${port}" -j ACCEPT 2>/dev/null \
                && echo "✅ iptables 已放行 UDP ${port}(重启可能失效,建议 apt install iptables-persistent 持久化)" \
                || echo "⚠️ iptables 放行失败,请手动配置"
        else
            echo "✅ iptables 规则已存在,无需重复添加"
        fi
    else
        echo "ℹ️ 未检测到 ufw/firewalld/iptables,跳过自动放行,请自行确认防火墙状态。"
    fi
    echo "⚠️ 重要:阿里云/腾讯云/AWS 等云厂商的"安全组/网络ACL"需要额外在控制台放行 UDP ${port},本脚本无法代为操作,请务必手动检查——这是"连接不通"最常见的原因。"
}

# ---------- 生成 systemd 预检脚本(ExecStartPre,启动前把能查的都查一遍,避免秒退) ----------
write_preflight_script() {
    cat > hysteria2-preflight.sh <<'PFEOF'
#!/usr/bin/env bash
# Hysteria2 启动前健康检查:配置语法 / 证书有效期 / 端口占用 / DNS / 出网连通性
# 任一致命项不通过则直接非 0 退出,systemd 会 fail-fast 并记录清晰原因,
# 而不是让主进程带着坏配置起来又立刻崩溃、在日志里只留一行看不懂的报错。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONFIG="server.yaml"
CERT="cert.pem"
KEY="key.pem"

fail() { echo "❌ [preflight] $1" >&2; exit 1; }
warn() { echo "⚠️ [preflight] $1" >&2; }

# 1) 配置文件存在 + 关键字段完整
[[ -f "$CONFIG" ]] || fail "配置文件 $CONFIG 不存在"
grep -q '^listen:' "$CONFIG" || fail "配置缺少 listen 字段"
grep -q '^auth:'   "$CONFIG" || fail "配置缺少 auth 字段"

PORT=$(grep '^listen:' "$CONFIG" | grep -oE '[0-9]+' | head -n1)
[[ "$PORT" =~ ^[0-9]+$ ]] || fail "无法从配置解析监听端口"

# 2) 证书存在 + 未过期(7天内过期只警告,已过期直接阻止启动)
[[ -f "$CERT" && -f "$KEY" ]] || fail "证书文件缺失: $CERT / $KEY"
if ! openssl x509 -in "$CERT" -noout -checkend 0 >/dev/null 2>&1; then
    fail "证书已过期: $CERT,请重新生成后再启动"
fi
if ! openssl x509 -in "$CERT" -noout -checkend 604800 >/dev/null 2>&1; then
    warn "证书将在 7 天内过期,建议尽快更换"
fi

# 3) 端口是否已被其他进程占用(重启场景下自己占用自己不算)
if command -v ss >/dev/null 2>&1; then
    OWNER_PID=$(ss -ulnp 2>/dev/null | awk -v p=":$PORT" '$5 ~ p {print $0}' | grep -oP 'pid=\K[0-9]+' | head -n1 || true)
    if [[ -n "$OWNER_PID" && -n "${MAINPID:-}" && "$OWNER_PID" != "${MAINPID:-}" ]]; then
        fail "UDP 端口 ${PORT} 已被其他进程(PID ${OWNER_PID})占用,请先释放该端口"
    fi
fi

# 4) DNS 解析(尽力而为,不阻断启动,只强提示——Hysteria2 本身接收连接不依赖出网)
if ! getent hosts github.com >/dev/null 2>&1; then
    warn "DNS 解析异常,可能影响后续自动更新,不影响当前服务对外提供连接"
fi

# 5) 出网连通性(同上,仅提示)
if command -v curl >/dev/null 2>&1; then
    if ! curl -fsL --max-time 5 https://www.gstatic.com/generate_204 >/dev/null 2>&1; then
        warn "出网连通性检测失败,若只需被动接受客户端连接可忽略"
    fi
fi

echo "✅ [preflight] 检查通过,端口=${PORT}"
exit 0
PFEOF
    chmod +x hysteria2-preflight.sh
    echo "✅ 已生成 hysteria2-preflight.sh(systemd 启动前会自动执行)。"
}

# ---------- 生成 systemd 单元文件(安全加固版) ----------
write_systemd_unit() {
    # 用专用系统账号运行,而不是 root:即使 Hysteria2 出漏洞,
    # 攻击者拿到的也只是一个受限账号的权限,而不是整台 VPS 的 root。
    if [[ "$(id -u)" -eq 0 ]]; then
        if ! id "$RUN_USER" >/dev/null 2>&1; then
            if command -v useradd >/dev/null 2>&1; then
                useradd --system --no-create-home --shell /usr/sbin/nologin "$RUN_USER" 2>/dev/null \
                    && echo "✅ 已创建专用服务账号: $RUN_USER(无 shell、不可登录)" \
                    || echo "⚠️ 创建账号 $RUN_USER 失败,请手动创建后重跑本脚本。"
            else
                echo "⚠️ 未找到 useradd,无法自动创建专用账号,请手动创建 $RUN_USER 后重跑。"
            fi
        fi
        chown -R "${RUN_USER}:${RUN_GROUP}" "$SCRIPT_DIR" 2>/dev/null || true
    else
        echo "⚠️ 当前非 root 运行,跳过专用账号创建/chown,systemd 单元仍会写入 User=${RUN_USER},请自行确保该账号存在且有权限访问 ${SCRIPT_DIR}。"
    fi

    cat > hysteria2.service <<EOF
[Unit]
Description=Hysteria2 Server
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_GROUP}
WorkingDirectory=${SCRIPT_DIR}
Environment=GOMEMLIMIT=${MEMORY_LIMIT}

# 启动前健康检查:配置语法 / 证书有效期 / 端口占用 / DNS / 出网连通性
ExecStartPre=${SCRIPT_DIR}/hysteria2-preflight.sh
ExecStart=${SCRIPT_DIR}/${BIN_NAME} server -c ${SCRIPT_DIR}/server.yaml

Restart=on-failure
RestartSec=5

# ---- 资源限制 ----
MemoryMax=100M
MemoryHigh=90M
TasksMax=64

# ---- 权限最小化 / 禁止提权 ----
# <1024 端口需要 CAP_NET_BIND_SERVICE;>=1024 端口理论上不需要,但保留该单一能力
# 影响不大,换低端口时不用再改这里。
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
RestrictSUIDSGID=true
RemoveIPC=true

# ---- 文件系统访问范围限制 ----
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${SCRIPT_DIR}
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
ProcSubset=pid

# ---- 网络能力范围限制 ----
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true

# ---- syscall 白名单(限制 syscall 范围) ----
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @mount @debug @cpu-emulation @obsolete @swap @raw-io
SystemCallErrorNumber=EPERM
SystemCallArchitectures=native

# ---- 日志:统一交给 journald,并做速率限制,防止异常刷屏把磁盘写满 ----
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hysteria2
LogRateLimitIntervalSec=30s
LogRateLimitBurst=1000

[Install]
WantedBy=multi-user.target
EOF
    echo "📄 已生成 hysteria2.service(安全加固版,未自动安装)。安装/启用:"
    echo "   sudo cp hysteria2.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now ${SERVICE_NAME}"
}

# ---------- 生成 journald 日志限额(全局,防止 journal 无限增长) ----------
write_journald_dropin() {
    mkdir -p journald-dropin
    cat > journald-dropin/hysteria2.conf <<'EOF'
# 建议安装到 /etc/systemd/journald.conf.d/hysteria2.conf 后:
#   sudo systemctl restart systemd-journald
[Journal]
SystemMaxUse=200M
SystemKeepFree=500M
MaxRetentionSec=14day
Compress=yes
EOF
    echo "📄 已生成 journald-dropin/hysteria2.conf(限制 journal 日志总量,默认低级别、由 journald 统一管理)。安装:"
    echo "   sudo mkdir -p /etc/systemd/journald.conf.d && sudo cp journald-dropin/hysteria2.conf /etc/systemd/journald.conf.d/ && sudo systemctl restart systemd-journald"
}

# ---------- 生成带健康检查/回滚的更新脚本 ----------
write_update_script() {
    cat > hysteria2-update.sh <<UPEOF
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
cd "\$SCRIPT_DIR"

LOCK_FILE="/tmp/${SERVICE_NAME}-update.lock"
SERVICE="${SERVICE_NAME}"
BACKUP_DIR="./backup"

# 更新加锁,避免 cron/手动同时触发导致并发执行互相踩踏
exec 200>"\$LOCK_FILE"
if ! flock -n 200; then
    echo "❌ 已有更新任务在执行,本次退出。"
    exit 1
fi

echo "🔄 [\$(date '+%F %T')] 开始检查更新..."

CUR_BIN=\$(ls hysteria-linux-* 2>/dev/null | head -n1 || true)
if [[ -z "\$CUR_BIN" ]]; then
    echo "❌ 未找到当前二进制,无法更新"
    exit 1
fi

mkdir -p "\$BACKUP_DIR"
cp -f "\$CUR_BIN" "\$BACKUP_DIR/\${CUR_BIN}.bak"
cp -f server.yaml "\$BACKUP_DIR/server.yaml.bak" 2>/dev/null || true

# ---- 更新前健康检查:当前服务是否正常运行 ----
if systemctl is-active --quiet "\$SERVICE" 2>/dev/null; then
    echo "✅ 更新前健康检查通过:当前服务运行正常"
else
    echo "⚠️ 更新前健康检查:当前服务未在运行(仍继续更新流程)"
fi

# ---- 下载并校验新版本(复用主脚本逻辑,不新起一份下载代码) ----
if ! bash "\${SCRIPT_DIR}/hysteria2.sh" --update-only; then
    echo "❌ 更新下载/校验失败,未做任何变更,当前版本继续运行"
    exit 1
fi

# ---- 重启并做启动后健康检查,失败自动回滚 ----
systemctl restart "\$SERVICE"
sleep 3

if systemctl is-active --quiet "\$SERVICE"; then
    echo "✅ [\$(date '+%F %T')] 更新完成,服务运行正常。"
    rm -rf "\${BACKUP_DIR:?}"/*
    exit 0
fi

echo "❌ 新版本启动失败,3 秒后自动回滚到更新前版本..."
cp -f "\$BACKUP_DIR/\${CUR_BIN}.bak" "\$CUR_BIN"
cp -f "\$BACKUP_DIR/server.yaml.bak" server.yaml 2>/dev/null || true
chmod +x "\$CUR_BIN"
systemctl restart "\$SERVICE"
sleep 2

if systemctl is-active --quiet "\$SERVICE"; then
    echo "✅ 已回滚到更新前版本,服务恢复正常。"
    exit 1
else
    echo "❌ 回滚后服务仍无法启动,请手动检查: journalctl -u \${SERVICE} -n 50 --no-pager"
    exit 1
fi
UPEOF
    chmod +x hysteria2-update.sh
    echo "📄 已生成 hysteria2-update.sh(更新前健康检查 + 更新后校验 + 失败自动回滚 + 加锁防并发)。"
    echo "   可配 systemd timer 或 cron 定期执行,例如每天凌晨: 0 4 * * * ${SCRIPT_DIR}/hysteria2-update.sh >> ${SCRIPT_DIR}/update.log 2>&1"
}

# ---------- 打印连接信息 ----------
print_connection_info() {
    local IP="$1"
    echo "🎉 Hysteria2 部署成功!"
    echo "=========================================================================="
    echo "📋 服务器信息:"
    echo "   🌐 IP地址: $IP"
    echo "   🔌 端口(UDP): $SERVER_PORT"
    echo "   🔑 密码: $AUTH_PASSWORD  (已保存于 $PASSWORD_FILE)"
    echo "   🔏 证书 pinSHA256: $PIN_SHA256"
    echo "   🧠 GOMEMLIMIT: $MEMORY_LIMIT(可用 GOMEMLIMIT=xxx 环境变量覆盖)"
    echo ""
    echo "📱 节点链接(SNI 仅用于 TLS 握手,连接安全性由 pinSHA256 证书指纹保证):"
    echo "hysteria2://${AUTH_PASSWORD}@${IP}:${SERVER_PORT}?sni=${SNI}&alpn=${ALPN}&pinSHA256=${PIN_SHA256}#Hy2"
    echo ""
    echo "📄 客户端配置文件:"
    echo "server: ${IP}:${SERVER_PORT}"
    echo "auth: ${AUTH_PASSWORD}"
    echo "tls:"
    echo "  sni: ${SNI}"
    echo "  alpn: [\"${ALPN}\"]"
    echo "  pinSHA256: \"${PIN_SHA256}\""
    echo "socks5:"
    echo "  listen: 127.0.0.1:1080"
    echo "http:"
    echo "  listen: 127.0.0.1:8080"
    echo "=========================================================================="
    echo "⚠️ 排查"连接不通"请按顺序检查:"
    echo "   1) systemctl status ${SERVICE_NAME} —— 进程是否真的在跑"
    echo "   2) journalctl -u ${SERVICE_NAME} -n 50 --no-pager —— 是否 preflight 就失败了"
    echo "   3) ss -ulnp | grep ${SERVER_PORT} —— 本机是否真的在监听该 UDP 端口"
    echo "   4) 本机防火墙(已尝试自动放行,见上面日志)"
    echo "   5) 云厂商安全组/网络ACL(脚本无法代为操作,必须去控制台手动放行 UDP ${SERVER_PORT})"
    echo "   6) 部分运营商/校园网会限制或屏蔽 UDP/QUIC,换个网络环境测试排除"
    echo "=========================================================================="
    echo "⚠️ 前台直接运行的进程会在 SSH 断开后被杀掉,长期挂机请安装 hysteria2.service:"
    echo "   sudo cp hysteria2.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now ${SERVICE_NAME}"
}

# ---------- 主逻辑 ----------
main() {
    download_binary

    if [[ "$UPDATE_ONLY" -eq 1 ]]; then
        echo "✅ --update-only 模式:已完成下载与校验,退出(不改证书/配置/systemd,不启动)。"
        exit 0
    fi

    ensure_cert
    PIN_SHA256="$(compute_pin_sha256)"
    write_config
    open_firewall_port "$SERVER_PORT"
    write_preflight_script
    write_systemd_unit
    write_journald_dropin
    write_update_script
    SERVER_IP=$(get_server_ip)
    print_connection_info "$SERVER_IP"

    echo ""
    echo "🚀 即将前台启动 Hysteria2(仅用于验证配置是否正常;正式使用请安装上面的 systemd 服务)..."
    echo "   若只是想验证,启动后另开一个终端执行: ss -ulnp | grep ${SERVER_PORT}"
    export GOMEMLIMIT="$MEMORY_LIMIT"
    ./hysteria2-preflight.sh || { echo "❌ 预检未通过,已取消启动,请根据上面的报错修复后重试。"; exit 1; }
    exec "$BIN_PATH" server -c server.yaml
}

main "$@"
