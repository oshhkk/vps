#!/usr/bin/env bash
# Hysteria2 部署脚本 —— Pterodactyl 容器 · 精简版
# 用法: bash hysteria2.sh            部署并运行
#       bash hysteria2.sh diagnose   诊断
set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
cd "$SCRIPT_DIR"
export HOME="${SCRIPT_DIR}/.home"
mkdir -p "$HOME"

CERT_FILE="cert.pem"
KEY_FILE="key.pem"
DOMAIN_FILE="domain.txt"        # 只存域名本身，不含任何凭据；用于判断是否已经签过证书
ALPN="h3"
MEMORY_LIMIT="${GOMEMLIMIT:-70MiB}"
GITHUB_REPO="apernet/hysteria"
LOG_LEVEL="${HYSTERIA_LOG_LEVEL:-warn}"
ACME_HOME="${HOME}/.acme.sh"
EPHEMERAL_CERT="${EPHEMERAL_CERT:-0}"   # 1=不保留证书，每次重新签发(会撞 Let's Encrypt 限流，不建议)

log() { echo "$@"; }
err() { echo "$@" >&2; }

MODE="deploy"
[[ "${1:-}" == "diagnose" ]] && MODE="diagnose"

check_deps() {
    local missing=()
    for bin in curl openssl sha256sum grep sed awk uname ss; do
        command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
    done
    [[ "${#missing[@]}" -eq 0 ]] || { err "缺少依赖: ${missing[*]}"; exit 1; }
}
check_deps

# ---------- 端口：只信面板注入的环境变量 ----------
if [[ -n "${SERVER_PORT:-}" ]]; then
    :
elif [[ -n "${PORT:-}" ]]; then
    SERVER_PORT="$PORT"
elif [[ -f server.yaml ]]; then
    SERVER_PORT=$(grep -E '^listen:' server.yaml | sed -E 's/^listen:\s*":?([0-9]+)".*/\1/')
else
    err "未检测到 SERVER_PORT/PORT 环境变量，也没有已有配置。去面板 Startup 页确认变量名，或 SERVER_PORT=端口 bash $0"
    exit 1
fi
[[ "$SERVER_PORT" =~ ^[0-9]+$ && "$SERVER_PORT" -ge 1 && "$SERVER_PORT" -le 65535 ]] || { err "非法端口: $SERVER_PORT"; exit 1; }

arch_name() {
    case "$(uname -m | tr '[:upper:]' '[:lower:]')" in
        x86_64|amd64) echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        armv7*) echo arm ;;
        armv6*|armv5*|arm*) echo armv5 ;;
        i386|i686|x86) echo 386 ;;
        mipsel|mipsle) echo mipsle ;;
        riscv64) echo riscv64 ;;
        s390x) echo s390x ;;
        *) echo "" ;;
    esac
}
ARCH="${BIN_ARCH_OVERRIDE:-$(arch_name)}"
[[ -n "$ARCH" ]] || { err "无法识别架构: $(uname -m)"; exit 1; }
BIN_NAME="hysteria-linux-${ARCH}"
BIN_PATH="${SCRIPT_DIR}/${BIN_NAME}"

diagnose() {
    if [[ -f server.yaml ]]; then
        local port
        port=$(grep -E '^listen:' server.yaml | sed -E 's/^listen:\s*":?([0-9]+)".*/\1/')
        if ss -lun 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${port}\$"; then
            echo "OK: UDP ${port} 正在监听"
        else
            echo "FAIL: UDP ${port} 没有监听"
        fi
    else
        echo "FAIL: 没有 server.yaml"
    fi
    if [[ -f "$CERT_FILE" ]]; then
        if openssl x509 -in "$CERT_FILE" -noout -checkend 86400 >/dev/null 2>&1; then
            echo "OK: 证书未过期，到期时间 $(openssl x509 -in "$CERT_FILE" -noout -enddate | cut -d= -f2)"
        else
            echo "FAIL: 证书已过期"
        fi
    fi
    curl -fsL --max-time 5 https://api.ipify.org >/dev/null 2>&1 && echo "OK: 出网正常" || echo "WARN: 出网异常"
    echo "剩余原因只能在 Pterodactyl 面板 Network 页确认：该端口是否勾选/映射了 UDP。"
}
[[ "$MODE" == "diagnose" ]] && { diagnose; exit 0; }

# ---------- 密码：内存生成，不落盘 ----------
gen_secret() {
    local length="$1" charset='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!&*()-_+=~'
    local out=""
    while [[ ${#out} -lt $length ]]; do
        out+="$(head -c 512 /dev/urandom | LC_ALL=C tr -dc "$charset" || true)"
    done
    printf '%s' "${out:0:$length}"
}
AUTH_PASSWORD="$(gen_secret 128)"
OBFS_PASSWORD="$(gen_secret 32)"

detect_latest_version() {
    local api_url="https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=30" json version
    json=$(curl -fsSL --connect-timeout 10 --max-time 20 "$api_url") || { err "无法访问 GitHub API"; exit 1; }
    version=$(printf '%s\n' "$json" | awk '
        /"tag_name":/   { gsub(/[",]/,""); split($0,a,": "); tag=a[2] }
        /"draft":/      { gsub(/[",]/,""); split($0,a,": "); draft=a[2] }
        /"prerelease":/ { gsub(/[",]/,""); split($0,a,": "); pre=a[2]
            if (tag ~ /^app\/v[0-9]+\.[0-9]+\.[0-9]+$/ && draft=="false" && pre=="false") { print tag; exit }
        }')
    [[ -n "$version" ]] || { err "未获取到正式版本号"; exit 1; }
    printf '%s' "$version"
}
HYSTERIA_VERSION_TAG="$(detect_latest_version)"

verify_checksum() {
    local hash_url="https://github.com/apernet/hysteria/releases/download/${HYSTERIA_VERSION_TAG}/hashes.txt"
    local hashes expected actual
    hashes=$(curl -fsL --connect-timeout 10 --max-time 20 "$hash_url" 2>/dev/null) || return 1
    expected=$(printf '%s\n' "$hashes" | awk -v bin="$BIN_NAME" '{ n=split($NF,p,"/"); if (p[n]==bin) { print $1; exit } }' || true)
    [[ -n "$expected" ]] || return 1
    actual=$(sha256sum "$BIN_PATH" | awk '{print $1}')
    [[ "$expected" == "$actual" ]]
}

download_binary() {
    if [ -f "$BIN_PATH" ] && verify_checksum; then return; fi
    rm -f "$BIN_PATH"
    local url="https://github.com/apernet/hysteria/releases/download/${HYSTERIA_VERSION_TAG}/${BIN_NAME}"
    curl -fL --retry 3 --connect-timeout 30 -o "$BIN_PATH" "$url" || { err "下载失败"; exit 1; }
    chmod +x "$BIN_PATH"
    verify_checksum || { err "SHA256 校验失败"; rm -f "$BIN_PATH"; exit 1; }
}

# ---------- 证书：域名 ACME（按上面说明默认落盘）或自签 ----------
CONFIG_ENV_FILE="cf.env"

# 优先从本地配置文件读取域名/凭据 —— 这是最可靠的方式：Pterodactyl 面板 console 的 stdin
# 是否能正确转发给手动跑起来的子进程并不保证（实测两次交互式 read 都没等到输入，大概率是
# 这条链路没打通或被上层吞掉了），文件读取不依赖这条链路，同时也不会像命令行传参那样把
# Token 留在 console 历史记录里。
# 只挑出这三个变量对应的 KEY=VALUE 行，其他内容一律忽略 —— 不用 source，
# 避免文件里混入其他文字（比如误粘贴的 URL/命令）被当成 shell 命令执行。
if [[ -f "$CONFIG_ENV_FILE" ]]; then
    while IFS='=' read -r _k _v; do
        _v="${_v%$'\r'}"                    # 去掉可能的 CRLF 残留
        _v="${_v%\"}"; _v="${_v#\"}"        # 去掉包住的双引号（如果有）
        _v="${_v%\'}"; _v="${_v#\'}"        # 去掉包住的单引号（如果有）
        case "$_k" in
            DOMAIN)     DOMAIN="$_v" ;;
            CF_Token)   CF_Token="$_v" ;;
            CF_Zone_ID) CF_Zone_ID="$_v" ;;
        esac
    done < <(grep -E '^(DOMAIN|CF_Token|CF_Zone_ID)=' "$CONFIG_ENV_FILE")
    log "已从 ${CONFIG_ENV_FILE} 读取配置"
fi

prompt_domain() {
    [[ -n "${DOMAIN:-}" ]] && { echo "$DOMAIN"; return; }
    [[ -f "$DOMAIN_FILE" && "$EPHEMERAL_CERT" != "1" ]] && { cat "$DOMAIN_FILE"; return; }
    local _d
    err "未找到 ${CONFIG_ENV_FILE}，也没有传 DOMAIN 环境变量。"
    err "等待控制台输入域名，180 秒超时（如果一直卡住/没反应，说明这条 console 转发不通，"
    err "改用 ${CONFIG_ENV_FILE} 文件方式最可靠，见上一条回复里的说明）："
    if read -rp "域名: " -t 180 _d; then
        echo "$_d"
    else
        err "超时未收到输入，回退到自签证书。"
        echo ""
    fi
}

ensure_acme_cert() {
    local domain="$1"
    if [[ -f "$DOMAIN_FILE" && "$(cat "$DOMAIN_FILE")" == "$domain" && -f "$CERT_FILE" && -f "$KEY_FILE" && "$EPHEMERAL_CERT" != "1" ]]; then
        return   # 已有该域名的证书，跳过重新签发（避免撞 Let's Encrypt 限流）
    fi

    if [[ ! -x "${ACME_HOME}/acme.sh" ]]; then
        curl -fsSL https://get.acme.sh -o /tmp/acme_install.sh || { err "下载 acme.sh 安装脚本失败"; exit 1; }
        # 不传任何 --home/--nocron 之类的参数：get.acme.sh 自身有个已知 bug，
        # 重装流程会把已带 -- 的参数再加一次前缀，变成 ----home 这种乱码导致解析失败。
        # $HOME 已经在脚本开头被重定向到脚本目录下，acme.sh 默认就会装在 $HOME/.acme.sh，
        # 不需要显式传 --home；没有 crontab 只会打个提示，不影响安装。
        if ! bash /tmp/acme_install.sh > /tmp/acme_install.log 2>&1; then
            err "acme.sh 安装失败，日志如下："
            cat /tmp/acme_install.log >&2
            exit 1
        fi
        if [[ ! -x "${ACME_HOME}/acme.sh" ]]; then
            err "acme.sh 安装脚本执行完了，但没有生成 ${ACME_HOME}/acme.sh，日志如下："
            cat /tmp/acme_install.log >&2
            exit 1
        fi
    fi

    # CF_Token 只在这一次进程里用来签发证书，签发后 acme.sh 会把它存进自己的 $ACME_HOME 目录
    # （这是 acme.sh 自身续期机制的必要条件，不是本脚本额外加的持久化），本脚本不再单独存一份副本。
    if [[ -z "${CF_Token:-}" ]]; then
        err "等待控制台输入 Cloudflare Token/Zone ID，180 秒超时（同样建议改用 ${CONFIG_ENV_FILE} 文件）："
        read -rp "Cloudflare API Token: " -t 180 -s CF_Token || { err "超时未收到 Token，终止。"; exit 1; }
        echo
        read -rp "Zone ID: " -t 60 CF_Zone_ID || { err "超时未收到 Zone ID，终止。"; exit 1; }
    fi
    export CF_Token CF_Zone_ID

    "${ACME_HOME}/acme.sh" --issue --dns dns_cf -d "$domain" \
        --keylength ec-256 --server letsencrypt \
        || { err "证书申请失败，检查域名是否由该 Cloudflare 账号管理、Token 是否有 Zone:DNS:Edit 权限"; exit 1; }

    "${ACME_HOME}/acme.sh" --install-cert -d "$domain" --ecc \
        --key-file "${SCRIPT_DIR}/${KEY_FILE}" --fullchain-file "${SCRIPT_DIR}/${CERT_FILE}" \
        || { err "证书安装失败"; exit 1; }

    echo "$domain" > "$DOMAIN_FILE"
}

ensure_self_signed_cert() {
    local sni="${SNI_OVERRIDE:-www.bing.com}"
    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" && "$EPHEMERAL_CERT" != "1" ]]; then return; fi
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${sni}" 2>/dev/null
    chmod 600 "$KEY_FILE"
}

setup_tls() {
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
    fi
}

compute_pin_sha256() {
    openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 2>/dev/null | sed -E 's/^.*Fingerprint=//'
}

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
}

get_server_ip() {
    curl -fsL --max-time 8 https://api.ipify.org 2>/dev/null \
        || curl -fsL --max-time 8 https://ifconfig.me 2>/dev/null \
        || echo "${SERVER_IP:-YOUR_SERVER_IP}"
}

print_connection_info() {
    local IP="$1" insecure_flag="false"
    [[ "$USE_ACME" -eq 1 ]] || insecure_flag="true"
    local addr; [[ "$USE_ACME" -eq 1 ]] && addr="$DOMAIN_NAME" || addr="$IP"

    echo "部署成功。端口(UDP): ${SERVER_PORT}"
    if [[ "$USE_ACME" -eq 1 ]]; then
        echo "证书到期时间: $(openssl x509 -in "$CERT_FILE" -noout -enddate | cut -d= -f2)（到期前重新运行本脚本即可自动续期）"
    fi
    echo ""
    echo "节点链接:"
    if [[ "$USE_ACME" -eq 1 ]]; then
        echo "hysteria2://${AUTH_PASSWORD}@${addr}:${SERVER_PORT}?sni=${DOMAIN_NAME}&alpn=${ALPN}&obfs=salamander&obfs-password=${OBFS_PASSWORD}#Hy2"
    else
        echo "hysteria2://${AUTH_PASSWORD}@${addr}:${SERVER_PORT}?sni=${DOMAIN_NAME}&alpn=${ALPN}&obfs=salamander&obfs-password=${OBFS_PASSWORD}&pinSHA256=$(compute_pin_sha256)#Hy2"
    fi
    echo ""
    echo "sing-box outbound:"
    cat <<SINGBOX
{
  "type": "hysteria2",
  "server": "${addr}",
  "server_port": ${SERVER_PORT},
  "password": "${AUTH_PASSWORD}",
  "obfs": { "type": "salamander", "password": "${OBFS_PASSWORD}" },
  "tls": { "enabled": true, "server_name": "${DOMAIN_NAME}", "insecure": ${insecure_flag}, "alpn": ["${ALPN}"] }
}
SINGBOX
    echo ""
    echo "注意：密码不落盘，进程退出后这份信息就是唯一副本，请立刻复制保存好；重启本脚本会生成新密码。"
}

main() {
    download_binary
    setup_tls
    write_config
    print_connection_info "$(get_server_ip)"
    export GOMEMLIMIT="$MEMORY_LIMIT" HYSTERIA_LOG_LEVEL="$LOG_LEVEL"
    exec "$BIN_PATH" server -c server.yaml
}

main "$@"
