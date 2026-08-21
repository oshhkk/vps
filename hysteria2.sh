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
# SNI 仅作为 TLS 握手时的 Server Name 使用,不代表服务器拥有该域名的身份,
# 客户端的连接安全性由下面自动生成的 pinSHA256 证书指纹保证,而不是域名本身。
SNI="${SNI_OVERRIDE:-www.bing.com}"
ALPN="h3"
MEMORY_LIMIT="${GOMEMLIMIT:-70MiB}"   # Go 运行时软内存上限;100MB 总预算里给系统/其他进程留出余量
GITHUB_REPO="apernet/hysteria"
# ------------------------------

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
else
    SERVER_PORT="${SERVER_PORT:-$DEFAULT_PORT}"
    parse_port "$SERVER_PORT"
    echo "⚙️ 未提供端口参数,使用默认端口: $SERVER_PORT"
fi

# ---------- 密码:环境变量 > 已保存的密码 > 自动生成(脚本开箱即用,环境变量只是可选覆盖) ----------
sanitize_password() {
    # 双引号 YAML 字符串里不能安全出现的字符,直接拒绝而不是悄悄改写
    if [[ "$1" == *'"'* || "$1" == *'\'* ]]; then
        echo "❌ AUTH_PASSWORD 中包含引号或反斜杠,可能破坏配置文件格式,请更换密码后重试。"
        exit 1
    fi
}

if [[ -n "${AUTH_PASSWORD:-}" ]]; then
    sanitize_password "$AUTH_PASSWORD"
    echo "✅ 使用环境变量指定的密码"
elif [[ -f "$PASSWORD_FILE" ]]; then
    # 用 tr 去掉首尾换行/回车:$(...) 本身只会去掉末尾的 \n,
    # 如果文件是手动创建/在 Windows 下编辑过(CRLF),cat 会残留一个 \r 混进密码里,
    # 进而污染 server.yaml 和 hysteria2:// 分享链接。
    AUTH_PASSWORD=$(tr -d '\r\n' < "$PASSWORD_FILE")
    echo "✅ 检测到已保存的密码($PASSWORD_FILE),复用它以免重复运行时密码跟着变"
else
    AUTH_PASSWORD=$(openssl rand -hex 16)   # hex 而非 base64:避免 +/= 之类的字符把下面的 hysteria2:// 分享链接解析错乱
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
        armv7*)              echo "arm" ;;      # 尽力而为
        armv6*|armv5*|arm*)  echo "armv5" ;;     # 尽力而为,老旧/低端设备兜底
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
    # 不依赖 jq：GitHub API 默认返回“每行一个字段”的美化 JSON，逐行匹配 tag_name / draft / prerelease
    # 注意:apernet/hysteria 仓库同时会为 core/vX.Y.Z、extras/vX.Y.Z、app/vX.Y.Z 三个 Go
    # 子模块各打一次同版本号的 tag,只有 app/ 这个才是带编译好二进制资产的正式发布,
    # 所以这里必须精确匹配 app/ 前缀,不能放宽,否则可能选中 core/extras 的 tag 导致后面下载 404。
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
# 只负责“计算并比对”,不做删除/退出等副作用;返回 0=通过,1=未通过,由调用方决定怎么处理。
verify_checksum() {
    local hash_url="https://github.com/apernet/hysteria/releases/download/${HYSTERIA_VERSION_TAG}/hashes.txt"
    local hashes expected actual
    if ! hashes=$(curl -fsL --connect-timeout 10 --max-time 20 "$hash_url" 2>/dev/null); then
        echo "⚠️ 未能获取官方 hashes.txt(${HYSTERIA_VERSION_TAG}),无法验证二进制完整性。"
        return 1
    fi
    # 官方 hashes.txt 里文件名带 "build/" 目录前缀(如 "build/hysteria-linux-amd64"),
    # 因此用 awk 取路径最后一段(basename)做精确比较,而不是假设文件名前面直接是空白。
    # 这样也不会和 hysteria-linux-amd64-avx 这类变体前缀撞在一起。
    # 用 || true 兜底:awk 正常处理但没匹配到时本身退出码是 0,这里加只是防御性写法。
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
# 注意:Hysteria2 的 pinSHA256 校验的是叶子证书本身的整体指纹(openssl x509 -fingerprint),
# 不是 SPKI/公钥指纹(那是 HPKP/移动端证书钉扎常用的另一种方案,数值完全不同、不通用)。
# 官方文档与代码行为均以整证书指纹为准,这里维持原实现,不要改成 SPKI 算法。
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
        echo "ℹ️ 已按 SERVER_BW_UP/SERVER_BW_DOWN 写入 bandwidth 段(用作拥塞控制/BBR 参考值,不是访问限速开关,请按服务器实际带宽填写)。"
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
    chmod 600 server.yaml   # 该文件明文包含 AUTH_PASSWORD,权限需要和 auth.pass/key.pem 一致

    if ! grep -q '^listen:' server.yaml || ! grep -q '^auth:' server.yaml; then
        echo "❌ 配置文件生成异常(缺少关键字段),已终止,不会启动服务。"
        exit 1
    fi
    echo "✅ 写入配置 server.yaml(端口=${SERVER_PORT}, SNI=${SNI}[仅 TLS SNI], ALPN=${ALPN})。"
}

# ---------- 获取服务器公网 IP ----------
# 优先用外部探测服务而不是本机网卡地址(hostname -I):绝大多数云服务器(阿里云/腾讯云/AWS 等)
# 网卡上看到的是内网/私有 IP,真正对外的公网 IP 必须靠外部服务回显才能拿到,
# 直接信本机网卡地址在 NAT 环境下会把内网 IP 当成公网 IP 塞进分享链接,导致客户端连不上。
# hostname -I 仅在两个外部服务都不可用时,作为“尽力而为”的最后兜底,并明确提示可能不准确。
get_server_ip() {
    local ip local_ip
    ip=$(curl -fsL --max-time 8 https://api.ipify.org 2>/dev/null) \
        || ip=$(curl -fsL --max-time 8 https://ifconfig.me 2>/dev/null) \
        || ip=""
    if [[ -z "$ip" ]]; then
        local_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "$local_ip" ]]; then
            echo "⚠️ 无法访问外部 IP 探测服务,回退使用本机网卡地址 $local_ip" >&2
            echo "⚠️ 如果服务器在 NAT/内网环境(多数云主机默认如此),这可能不是公网可达地址,请手动核实实际公网 IP。" >&2
            ip="$local_ip"
        else
            ip="YOUR_SERVER_IP"
        fi
    fi
    echo "$ip"
}

# ---------- 生成可选的 systemd 单元文件(不会自动安装/启用) ----------
write_systemd_unit() {
    local user_block=""
    if [[ -n "${RUN_USER:-}" ]]; then
        user_block="User=${RUN_USER}
Group=${RUN_GROUP:-$RUN_USER}"
        echo "ℹ️ systemd 单元将以非 root 用户 ${RUN_USER} 运行(注意该用户需有权限绑定端口 ${SERVER_PORT},<1024 端口需额外授予 CAP_NET_BIND_SERVICE)。"
    else
        echo "ℹ️ 未设置 RUN_USER,systemd 单元默认以 root 运行;如需低权限运行可 export RUN_USER=xxx 后重新执行本脚本。"
    fi
    cat > hysteria2.service <<EOF
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
Type=simple
WorkingDirectory=${SCRIPT_DIR}
${user_block}
Environment=GOMEMLIMIT=${MEMORY_LIMIT}
ExecStart=${SCRIPT_DIR}/${BIN_NAME} server -c ${SCRIPT_DIR}/server.yaml
Restart=on-failure
RestartSec=5
MemoryMax=100M
MemoryHigh=90M
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    echo "📄 已生成 hysteria2.service(未自动安装)。想让它常驻、断开 SSH 也不掉线,可执行:"
    echo "   sudo cp hysteria2.service /etc/systemd/system/ && sudo systemctl enable --now hysteria2"
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
    echo "⚠️ Hysteria2 使用 UDP/QUIC 协议,请确认云厂商安全组 + 本机防火墙(ufw/iptables/firewalld)"
    echo "   已放行 UDP ${SERVER_PORT} 端口 —— 进程启动成功不代表公网一定能连通,请务必自行测试连接。"
    echo "⚠️ 前台直接运行的进程会在 SSH 断开后被杀掉。"
    echo "   长期挂机请用 nohup/screen/tmux,或安装上面生成的 hysteria2.service。"
}

# ---------- 主逻辑 ----------
# 顺序:依赖检查 → 端口/密码 → 架构检测 → 最新版本检测 → 下载 → SHA256 校验
#      → 证书检查/生成 → fingerprint 计算 → 配置生成/检查 → systemd → 启动
main() {
    download_binary
    ensure_cert
    PIN_SHA256="$(compute_pin_sha256)"
    write_config
    write_systemd_unit
    SERVER_IP=$(get_server_ip)
    print_connection_info "$SERVER_IP"
    export GOMEMLIMIT="$MEMORY_LIMIT"
    echo "🚀 启动 Hysteria2 服务器..."
    exec "$BIN_PATH" server -c server.yaml
}

main "$@"
