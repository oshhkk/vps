#!/usr/bin/env bash
# Hysteria2 部署脚本 —— 适配 Pterodactyl 容器环境（无 root / 无 systemd）
# 用法:
#   bash hysteria2.sh              首次部署 / 更新
#   bash hysteria2.sh diagnose     诊断
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Pterodactyl 容器里 $HOME 经常没设对，acme.sh 依赖 $HOME，这里强制收敛到脚本目录下，
# 保证无论面板怎么调用这个脚本，acme.sh 的证书/账号数据都在同一个可写、可预期的位置。
export HOME="${SCRIPT_DIR}/.home"
mkdir -p "$HOME"

CERT_FILE="cert.pem"
KEY_FILE="key.pem"
PASSWORD_FILE="auth.pass"
OBFS_PASSWORD_FILE="obfs.pass"
DOMAIN_FILE="domain.txt"
CF_CRED_FILE=".cf_credentials"
ALPN="h3"
MEMORY_LIMIT="${GOMEMLIMIT:-70MiB}"
GITHUB_REPO="apernet/hysteria"
LOG_LEVEL="${HYSTERIA_LOG_LEVEL:-warn}"
ACME_HOME="${SCRIPT_DIR}/.acme.sh"
PID_FILE="${SCRIPT_DIR}/hysteria2.pid"

log()  { echo "$@"; }
err()  { echo "$@" >&2; }

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "Hysteria2 部署脚本（Pterodactyl 容器专用 · ACME 证书 · Salamander 混淆 · 强密码）"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

MODE="deploy"
if [[ "${1:-}" == "diagnose" || "${1:-}" == "--diagnose" ]]; then
    MODE="diagnose"
fi

# ---------- 依赖检查 ----------
check_deps() {
    local missing=()
    for bin in curl openssl sha256sum grep sed awk uname ss; do
        command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
    done
    if [ "${#missing[@]}" -ne 0 ]; then
        err "❌ 缺少必要依赖: ${missing[*]}"
        err "   请在容器里手动安装（不同基础镜像命令不同，比如 apt-get / apk / yum）。"
        exit 1
    fi
}
check_deps

# ---------- 端口来源：优先用 Pterodactyl 面板注入的环境变量 ----------
# Pterodactyl 默认会给每个容器注入 SERVER_PORT / SERVER_IP，对应你在面板 Network 页分配的端口。
# 这是本环境下最关键的一点：必须监听这个端口，而不是脚本自己随便挑一个。
detect_pterodactyl_port() {
    if [[ -n "${SERVER_PORT:-}" ]]; then
        echo "$SERVER_PORT"
    elif [[ -n "${PORT:-}" ]]; then
        echo "$PORT"
    else
        echo ""
    fi
}

parse_port() {
    local candidate="$1"
    if [[ ! "$candidate" =~ ^[0-9]+$ ]] || [ "$candidate" -lt 1 ] || [ "$candidate" -gt 65535 ]; then
        err "❌ 非法端口: $candidate"
        exit 1
    fi
}

PANEL_PORT="$(detect_pterodactyl_port)"
if [[ -n "$PANEL_PORT" ]]; then
    SERVER_PORT="$PANEL_PORT"
    parse_port "$SERVER_PORT"
    log "✅ 检测到面板分配的端口环境变量: $SERVER_PORT（这是唯一会被 Docker 实际映射出去的端口）"
elif [[ -f server.yaml ]]; then
    SERVER_PORT=$(grep -E '^listen:' server.yaml | sed -E 's/^listen:\s*":?([0-9]+)".*/\1/')
    log "♻️  未检测到 SERVER_PORT 环境变量，复用已有配置里的端口: $SERVER_PORT"
    err "⚠️ 强烈建议去面板确认这个端口确实是 Network 页分配给你的端口，否则 Docker 不会转发流量进来。"
else
    err "❌ 既没有检测到 SERVER_PORT/PORT 环境变量，也没有已有配置。"
    err "   请到面板 Startup 页确认变量名，或者手动执行: SERVER_PORT=你的端口 bash $0"
    exit 1
fi

# ---------- 架构检测 ----------
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
[[ -n "$ARCH" ]] || { err "❌ 无法识别 CPU 架构: $(uname -m)"; exit 1; }
BIN_NAME="hysteria-linux-${ARCH}"
BIN_PATH="${SCRIPT_DIR}/${BIN_NAME}"

# ============================================================
#  诊断模式
# ============================================================
diagnose() {
    echo "==================== 连通性诊断 ===================="
    echo "环境变量线索（面板注入的端口/IP，供你和 Network 页比对）："
    env | grep -iE '^(server_port|server_ip|port)=' | sed 's/^/   /' || echo "   （没有匹配到 SERVER_PORT/SERVER_IP/PORT，去 Startup 页确认变量名）"

    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
        echo "✅ hysteria2 进程存活 (PID $(cat "$PID_FILE"))"
    else
        echo "❌ hysteria2 进程没有在跑（或者是被面板通过其他方式启动的，pidfile 对不上）"
    fi

    if [[ -f server.yaml ]]; then
        local port
        port=$(grep -E '^listen:' server.yaml | sed -E 's/^listen:\s*":?([0-9]+)".*/\1/')
        if ss -lun 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${port}\$"; then
            echo "✅ 容器内部 UDP ${port} 正在监听"
        else
            echo "❌ 容器内部没有监听 UDP ${port}"
        fi
    else
        echo "⚠️ 未找到 server.yaml"
    fi

    if [[ -f "$CERT_FILE" ]]; then
        if openssl x509 -in "$CERT_FILE" -noout -checkend 86400 >/dev/null 2>&1; then
            echo "✅ 证书未过期"
            if [[ -f "$DOMAIN_FILE" ]]; then
                echo "   使用域名证书: $(cat "$DOMAIN_FILE")（客户端应把 insecure 设为 false）"
            else
                echo "   使用自签证书（客户端必须 insecure:true）"
            fi
        else
            echo "❌ 证书已过期"
        fi
    fi

    if curl -fsL --max-time 5 https://api.ipify.org >/dev/null 2>&1; then
        echo "✅ 容器出网正常"
    else
        echo "⚠️ 容器出网异常，会影响证书申请/续期和自动更新"
    fi

    echo "======================================================"
    echo "⚠️ 本机侧检查全部通过、但客户端仍连不上的话，99% 是面板 Network 页这个端口"
    echo "   没有同时映射 UDP（很多面板默认只给主分配端口开 TCP+UDP，额外端口可能只有 TCP，"
    echo "   务必去 Network 页确认端口类型，这一步脚本在容器内部完全查不出来）。"
}

if [[ "$MODE" == "diagnose" ]]; then
    diagnose
    exit 0
fi

# ---------- 强随机密码生成（大小写+数字+特殊字符，URL/YAML/JSON/heredoc 全兼容） ----------
# 字符集特意排除了 " ' \ $ ` @ : / ? # % 空格 —— 这些要么会破坏 YAML/JSON 引号，
# 要么在 hysteria2:// 分享链接里是保留字符需要转义，要么（$ 和反引号）在本脚本生成
# server.yaml 用的是不加引号的 heredoc，包含 $(...) 会被 bash 当命令替换执行，属于真实的注入风险。
gen_strong_secret() {
    local length="$1"
    local charset='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!&*()-_+=~'
    local out=""
    local attempt=0
    while :; do
        out=""
        while [[ ${#out} -lt $length ]]; do
            out+="$(head -c 512 /dev/urandom | LC_ALL=C tr -dc "$charset" || true)"
        done
        out="${out:0:$length}"
        # 保险起见确认四类字符都出现了（128 位长度下概率上必然满足，这里只是兜底）
        if [[ "$out" =~ [A-Z] && "$out" =~ [a-z] && "$out" =~ [0-9] && "$out" =~ [!\&\*\(\)_+=~-] ]]; then
            break
        fi
        attempt=$((attempt+1))
        [[ $attempt -lt 20 ]] || break
    done
    printf '%s' "$out"
}

# ---------- 认证密码 ----------
if [[ -n "${AUTH_PASSWORD:-}" ]]; then
    log "✅ 使用环境变量指定的密码"
elif [[ -f "$PASSWORD_FILE" ]]; then
    AUTH_PASSWORD=$(tr -d '\r\n' < "$PASSWORD_FILE")
    log "✅ 复用已保存的密码 ($PASSWORD_FILE)"
else
    AUTH_PASSWORD="$(gen_strong_secret 128)"
    echo "$AUTH_PASSWORD" > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
    log "🔑 已生成 128 位强密码（大小写+数字+特殊字符）并保存到 $PASSWORD_FILE"
fi

# ---------- 混淆密码 ----------
if [[ -f "$OBFS_PASSWORD_FILE" ]]; then
    OBFS_PASSWORD=$(tr -d '\r\n' < "$OBFS_PASSWORD_FILE")
else
    OBFS_PASSWORD="$(gen_strong_secret 32)"
    echo "$OBFS_PASSWORD" > "$OBFS_PASSWORD_FILE"
    chmod 600 "$OBFS_PASSWORD_FILE"
    log "🔑 已生成 32 位混淆(obfs)密码并保存到 $OBFS_PASSWORD_FILE"
fi

# ---------- 最新版本 / 下载 / 校验（与之前一致） ----------
detect_latest_version() {
    err "🔍 正在查询 Hysteria 官方最新稳定版本..."
    local api_url="https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=30"
    local json version
    json=$(curl -fsSL --connect-timeout 10 --max-time 20 "$api_url") || { err "❌ 无法访问 GitHub API"; exit 1; }
    version=$(printf '%s\n' "$json" | awk '
        /"tag_name":/   { gsub(/[",]/,""); split($0,a,": "); tag=a[2] }
        /"draft":/      { gsub(/[",]/,""); split($0,a,": "); draft=a[2] }
        /"prerelease":/ { gsub(/[",]/,""); split($0,a,": "); pre=a[2]
            if (tag ~ /^app\/v[0-9]+\.[0-9]+\.[0-9]+$/ && draft=="false" && pre=="false") { print tag; exit }
        }')
    [[ -n "$version" ]] || { err "❌ 未获取到正式版本号"; exit 1; }
    printf '%s' "$version"
}
HYSTERIA_VERSION_TAG="$(detect_latest_version)"
HYSTERIA_VERSION="${HYSTERIA_VERSION_TAG#app/}"
log "✅ 最新稳定版本: ${HYSTERIA_VERSION}"

verify_checksum() {
    local hash_url="https://github.com/apernet/hysteria/releases/download/${HYSTERIA_VERSION_TAG}/hashes.txt"
    local hashes expected actual
    hashes=$(curl -fsL --connect-timeout 10 --max-time 20 "$hash_url" 2>/dev/null) || { err "⚠️ 无法获取 hashes.txt"; return 1; }
    expected=$(printf '%s\n' "$hashes" | awk -v bin="$BIN_NAME" '{ n=split($NF,p,"/"); if (p[n]==bin) { print $1; exit } }' || true)
    [[ -n "$expected" ]] || { err "⚠️ hashes.txt 里没有 ${BIN_NAME}"; return 1; }
    actual=$(sha256sum "$BIN_PATH" | awk '{print $1}')
    if [[ "$expected" == "$actual" ]]; then log "✅ SHA256 校验通过"; return 0; else err "⚠️ SHA256 不匹配"; return 1; fi
}

download_binary() {
    if [ -f "$BIN_PATH" ]; then
        if verify_checksum; then log "✅ 复用已存在的二进制"; return; fi
        rm -f "$BIN_PATH"
    fi
    local url="https://github.com/apernet/hysteria/releases/download/${HYSTERIA_VERSION_TAG}/${BIN_NAME}"
    log "⏳ 下载: $url"
    curl -fL --retry 3 --connect-timeout 30 -o "$BIN_PATH" "$url" || { err "❌ 下载失败"; rm -f "$BIN_PATH"; exit 1; }
    chmod +x "$BIN_PATH"
    verify_checksum || { err "❌ 校验失败，已删除"; rm -f "$BIN_PATH"; exit 1; }
}

# ---------- 域名 + 证书 ----------
prompt_domain() {
    if [[ -n "${DOMAIN:-}" ]]; then
        echo "$DOMAIN"
        return
    fi
    if [[ -f "$DOMAIN_FILE" ]]; then
        cat "$DOMAIN_FILE"
        return
    fi
    if [[ ! -t 0 ]]; then
        echo ""
        return
    fi
    read -rp "请输入你的域名（已托管在 Cloudflare，留空则使用自签证书）: " _d
    echo "$_d"
}

ensure_acme_cert() {
    local domain="$1"
    log "🌐 使用域名 ${domain} 申请 Let's Encrypt 证书（Cloudflare DNS 验证）..."

    if [[ ! -x "${ACME_HOME}/acme.sh" ]]; then
        log "⏳ 安装 acme.sh..."
        curl -fsSL https://get.acme.sh -o /tmp/acme_install.sh
        sh /tmp/acme_install.sh --home "$ACME_HOME" --nocron --accountemail "admin@${domain}" >/dev/null 2>&1 \
            || { err "❌ acme.sh 安装失败"; exit 1; }
    fi

    if [[ -f "$CF_CRED_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CF_CRED_FILE"
    fi
    if [[ -z "${CF_Token:-}" ]]; then
        if [[ ! -t 0 ]]; then
            err "❌ 未设置 CF_Token 环境变量，且当前无法交互输入，已终止。"
            exit 1
        fi
        read -rp "请输入 Cloudflare API Token: " CF_Token
        read -rp "请输入该域名的 Zone ID（域名概览页右侧可看到）: " CF_Zone_ID
        cat > "$CF_CRED_FILE" <<EOF
CF_Token="${CF_Token}"
CF_Zone_ID="${CF_Zone_ID}"
EOF
        chmod 600 "$CF_CRED_FILE"
        log "🔑 已保存 Cloudflare 凭据到 $CF_CRED_FILE（明文保存，权限已收紧为 600；这是本容器环境下唯一可行的方式，注意不要把这个文件传出去）。"
    fi
    export CF_Token CF_Zone_ID

    "${ACME_HOME}/acme.sh" --home "$ACME_HOME" --issue --dns dns_cf -d "$domain" \
        --keylength ec-256 --server letsencrypt \
        || { err "❌ 证书申请失败，请检查域名解析是否确实由这个 Cloudflare 账号/Zone 管理，以及 Token 权限是否包含 Zone:DNS:Edit。"; exit 1; }

    "${ACME_HOME}/acme.sh" --home "$ACME_HOME" --install-cert -d "$domain" --ecc \
        --key-file "${SCRIPT_DIR}/${KEY_FILE}" \
        --fullchain-file "${SCRIPT_DIR}/${CERT_FILE}" \
        || { err "❌ 证书安装失败"; exit 1; }

    echo "$domain" > "$DOMAIN_FILE"
    log "✅ 域名证书申请成功: ${domain}"
}

ensure_self_signed_cert() {
    local sni="${SNI_OVERRIDE:-www.bing.com}"
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        log "✅ 复用现有自签证书对"
        return
    fi
    log "🔑 生成自签证书（CN=${sni}）..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${sni}"
    chmod 600 "$KEY_FILE"
    echo "$sni" > .sni_used
}

setup_tls() {
    if [[ -f "$DOMAIN_FILE" && -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        # 已经部署过域名证书，检查是否需要续期即可，续期逻辑在后台循环里做
        DOMAIN_NAME=$(cat "$DOMAIN_FILE")
        USE_ACME=1
        return
    fi
    local d
    d="$(prompt_domain)"
    if [[ -n "$d" ]]; then
        ensure_acme_cert "$d"
        DOMAIN_NAME="$d"
        USE_ACME=1
    else
        ensure_self_signed_cert
        DOMAIN_NAME="${SNI_OVERRIDE:-www.bing.com}"
        USE_ACME=0
        log "ℹ️ 未提供域名，使用自签证书 + SNI 伪装（客户端需要 insecure:true / pinSHA256）。"
    fi
}

compute_pin_sha256() {
    openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 2>/dev/null | sed -E 's/^.*Fingerprint=//'
}

# ---------- 写配置 ----------
write_config() {
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
obfs:
  type: "salamander"
  salamander:
    password: "${OBFS_PASSWORD}"
quic:
  maxIdleTimeout: 10s
  maxIncomingStreams: 32
  initStreamReceiveWindow: 131072
  maxStreamReceiveWindow: 262144
  initConnReceiveWindow: 327680
  maxConnReceiveWindow: 655360
EOF
    chmod 600 server.yaml
    grep -q '^listen:' server.yaml || { err "❌ 配置生成异常"; exit 1; }
    log "✅ 写入配置 server.yaml（端口=${SERVER_PORT}, obfs=salamander）"
}

get_server_ip() {
    local ip
    ip=$(curl -fsL --max-time 8 https://api.ipify.org 2>/dev/null) \
        || ip=$(curl -fsL --max-time 8 https://ifconfig.me 2>/dev/null) \
        || ip="${SERVER_IP:-YOUR_SERVER_IP}"
    echo "$ip"
}

print_connection_info() {
    local IP="$1"
    local insecure_flag="false"
    [[ "$USE_ACME" -eq 1 ]] || insecure_flag="true"

    echo "🎉 Hysteria2 部署成功！"
    echo "=========================================================================="
    echo "📋 服务器信息:"
    echo "   🌐 地址: ${DOMAIN_NAME}（$( [[ "$USE_ACME" -eq 1 ]] && echo 真实域名+受信任证书 || echo 仅作SNI，实际连IP )）"
    echo "   🌐 IP: $IP"
    echo "   🔌 端口(UDP): $SERVER_PORT"
    echo "   🔑 密码: 已保存于 $PASSWORD_FILE（128位，不在这里明文回显）"
    echo "   🔑 obfs密码: 已保存于 $OBFS_PASSWORD_FILE"
    if [[ "$USE_ACME" -eq 0 ]]; then
        PIN_SHA256="$(compute_pin_sha256)"
        echo "   🔏 证书 pinSHA256: $PIN_SHA256"
    fi
    echo ""
    echo "📱 节点链接:"
    if [[ "$USE_ACME" -eq 1 ]]; then
        echo "hysteria2://${AUTH_PASSWORD}@${DOMAIN_NAME}:${SERVER_PORT}?sni=${DOMAIN_NAME}&alpn=${ALPN}&obfs=salamander&obfs-password=${OBFS_PASSWORD}#Hy2"
    else
        echo "hysteria2://${AUTH_PASSWORD}@${IP}:${SERVER_PORT}?sni=${DOMAIN_NAME}&alpn=${ALPN}&obfs=salamander&obfs-password=${OBFS_PASSWORD}&pinSHA256=${PIN_SHA256}#Hy2"
    fi
    echo ""
    echo "📱 sing-box outbound 配置:"
    cat <<SINGBOX
{
  "type": "hysteria2",
  "tag": "hy2-out",
  "server": "$( [[ "$USE_ACME" -eq 1 ]] && echo "$DOMAIN_NAME" || echo "$IP" )",
  "server_port": ${SERVER_PORT},
  "password": "${AUTH_PASSWORD}",
  "obfs": {
    "type": "salamander",
    "password": "${OBFS_PASSWORD}"
  },
  "tls": {
    "enabled": true,
    "server_name": "${DOMAIN_NAME}",
    "insecure": ${insecure_flag},
    "alpn": ["${ALPN}"]
  }
}
SINGBOX
    echo "=========================================================================="
    echo "⚠️ 务必去面板 Network 页确认这个端口(UDP ${SERVER_PORT})确实映射了 UDP，不只是 TCP。"
}

# ---------- 自我监督运行：没有 systemd，靠脚本自己 respawn + 证书到期自动重启加载新证书 ----------
CHILD_PID=""

cleanup() {
    err "🛑 收到停止信号，正在关闭..."
    [[ -n "$CHILD_PID" ]] && kill "$CHILD_PID" 2>/dev/null || true
    rm -f "$PID_FILE"
    exit 0
}
trap cleanup TERM INT

renewal_loop() {
    [[ "$USE_ACME" -eq 1 ]] || return
    while true; do
        sleep 43200   # 每 12 小时检查一次，acme.sh 内部会判断是否真的临近到期（默认60天内）
        if "${ACME_HOME}/acme.sh" --home "$ACME_HOME" --cron >/tmp/acme_renew.log 2>&1; then
            if grep -q "Cert success" /tmp/acme_renew.log 2>/dev/null; then
                log "🔄 证书已续期，安装新证书并重启 Hysteria2..."
                "${ACME_HOME}/acme.sh" --home "$ACME_HOME" --install-cert -d "$DOMAIN_NAME" --ecc \
                    --key-file "${SCRIPT_DIR}/${KEY_FILE}" \
                    --fullchain-file "${SCRIPT_DIR}/${CERT_FILE}" >/dev/null 2>&1 || true
                [[ -n "$CHILD_PID" ]] && kill "$CHILD_PID" 2>/dev/null || true
            fi
        fi
    done
}

run_supervised() {
    export GOMEMLIMIT="$MEMORY_LIMIT"
    export HYSTERIA_LOG_LEVEL="$LOG_LEVEL"

    if [[ "$USE_ACME" -eq 1 ]]; then
        renewal_loop &
        log "🔁 已启动证书自动续期后台检查（每 12 小时检查一次到期时间）"
    fi

    while true; do
        # ---- 启动前自检：端口占用 / 证书有效期 ----
        if ss -lun 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${SERVER_PORT}\$"; then
            err "❌ UDP ${SERVER_PORT} 已被占用（可能是上一个实例没退干净），10 秒后重试..."
            sleep 10
            continue
        fi
        if ! openssl x509 -in "$CERT_FILE" -noout -checkend 0 >/dev/null 2>&1; then
            err "❌ 证书已过期，等待续期后台任务处理，60 秒后重试..."
            sleep 60
            continue
        fi

        log "🚀 启动 Hysteria2（端口 ${SERVER_PORT}）..."
        "$BIN_PATH" server -c server.yaml &
        CHILD_PID=$!
        echo "$CHILD_PID" > "$PID_FILE"
        wait "$CHILD_PID"
        local code=$?
        err "⚠️ Hysteria2 进程退出 (exit=$code)，5 秒后自动重启..."
        sleep 5
    done
}

main() {
    download_binary
    setup_tls
    write_config
    SERVER_IP=$(get_server_ip)
    print_connection_info "$SERVER_IP"
    run_supervised
}

main "$@"
