#!/usr/bin/env bash
set -euo pipefail

# =========================================================================
# Xray VLESS + REALITY 部署脚本（无 root 版）
#   架构: 客户端 --VLESS+REALITY--> xray（直接监听你指定的端口）
#   不需要自己的域名、不需要 Cloudflare、不需要证书、不需要 caddy/nginx。
#   REALITY 不用你自己签的证书，而是握手时“借用”一个你指定的真实网站
#   （REALITY_DEST）的 TLS 身份：不认识的主动探测请求会被原样转发给那个
#   真实网站处理，回包和真的一模一样；只有拿着正确私钥+shortId的客户端
#   才能被 xray 识别并放行。
#
# 用法：
#   REALITY_NETWORK=xhttp REALITY_DEST=www.bing.com:443 bash xray-vless-reality.sh 3075
#   （端口作为第一个命令行参数，必填；也可以用 PORT=3075 环境变量代替）
#   REALITY_DEST 不填则用默认值，但强烈建议你自己挑一个、并用脚本自带的
#   check_reality_dest 测一下是否合适（见下面的说明）。
# =========================================================================

# ---------- 获取端口（命令行参数 > 环境变量，必须手动指定） ----------
if [[ $# -ge 1 && -n "${1:-}" ]]; then
    PORT="$1"
elif [[ -n "${PORT:-}" ]]; then
    :
else
    echo "❌ 必须指定端口，例如："
    echo "   bash $0 3075"
    echo "   或者 PORT=3075 bash $0"
    exit 1
fi

# ---------- 其他配置 ----------
UUID_FILE="uuid.txt"
XRAY_TAG="${XRAY_TAG:-latest}"
BASE_DIR="$(pwd)"

# REALITY_DEST：要“借用”身份的真实网站，格式 host:port（通常就是 443）。
# 要求：支持 TLS1.3、支持 HTTP/2、不能是被墙的站、最好是你所在地区正常人也会
# 访问的大站（这样即使有人分析访问模式也不显眼）。默认给一个常见示例，
# 但建议你自己挑一个换掉，换之前用下面的 check_reality_dest 测一下。
REALITY_DEST="${REALITY_DEST:-www.microsoft.com:443}"
REALITY_SNI="${REALITY_SNI:-${REALITY_DEST%%:*}}"
# 客户端 TLS 指纹伪装（只影响客户端连接配置/生成的链接，不影响服务端）
REALITY_FINGERPRINT="${REALITY_FINGERPRINT:-chrome}"
# 传输层：tcp（配合 xtls-rprx-vision，性能最好，默认）或 xhttp（更贴近普通网页
# 请求形态，个别对长连接裸 TCP 限制较多的网络环境下可能更稳，但开销更高）。
REALITY_NETWORK="${REALITY_NETWORK:-tcp}"
if [[ "$REALITY_NETWORK" == "tcp" ]]; then
    REALITY_FLOW="xtls-rprx-vision"
else
    REALITY_FLOW=""
fi
XHTTP_PATH_PREFIX="${XHTTP_PATH_PREFIX:-/api/v2/sync}"
XHTTP_PATH="${XHTTP_PATH:-${XHTTP_PATH_PREFIX}/$(openssl rand -hex 4)}"
XHTTP_MODE="${XHTTP_MODE:-auto}"

# CONNECT_ADDR：客户端连接用的地址（服务器公网 IP，或任意一个解析到这台机器
# 的域名——只是为了方便你自己记，REALITY 不需要它有证书）。不填的话脚本会
# 尝试自动探测公网 IP，探测不到就在最后提示你自己填。
CONNECT_ADDR="${CONNECT_ADDR:-}"
# ------------------------------

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "Xray VLESS + REALITY 部署脚本（无 root · 无证书 · 端口=$PORT）"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "🎭 REALITY_DEST: $REALITY_DEST"
echo "📡 传输方式: $REALITY_NETWORK$( [[ -n "$REALITY_FLOW" ]] && echo "  flow=$REALITY_FLOW" )"

# ---------- UUID：环境变量 > 已保存 > 自动生成 ----------
if [[ -n "${AUTH_UUID:-}" ]]; then
    CLIENT_UUID="$AUTH_UUID"
elif [[ -f "$UUID_FILE" ]]; then
    CLIENT_UUID=$(cat "$UUID_FILE")
    echo "✅ 复用已保存的 UUID（$UUID_FILE）"
else
    if command -v uuidgen >/dev/null 2>&1; then
        CLIENT_UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
    else
        CLIENT_UUID=$(openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')
    fi
    echo "$CLIENT_UUID" > "$UUID_FILE"
    chmod 600 "$UUID_FILE"
    echo "🔑 已生成新 UUID，保存于 $UUID_FILE"
fi

# ---------- 架构探测 ----------
arch_name() {
    local machine
    machine=$(uname -m | tr '[:upper:]' '[:lower:]')
    case "$machine" in
        x86_64|amd64)   echo "64" ;;
        aarch64|arm64)  echo "arm64-v8a" ;;
        armv7*)         echo "arm32-v7a" ;;
        i386|i686|x86)  echo "32" ;;
        mips64)         echo "mips64" ;;
        mips64el)       echo "mips64le" ;;
        mips)           echo "mips32" ;;
        mipsel|mipsle)  echo "mips32le" ;;
        riscv64)        echo "riscv64" ;;
        s390x)          echo "s390x" ;;
        *)               echo "" ;;
    esac
}
ARCH="${BIN_ARCH_OVERRIDE:-$(arch_name)}"
if [[ -z "$ARCH" ]]; then
    echo "❌ 无法识别 CPU 架构: $(uname -m)，可用 BIN_ARCH_OVERRIDE=64 手动指定。"
    exit 1
fi
ZIP_NAME="Xray-linux-${ARCH}.zip"
BIN_NAME="xray"
BIN_PATH="${BASE_DIR}/${BIN_NAME}"

verify_checksum() {
    local base_url dgst_url dgst expected actual
    if [[ "$XRAY_TAG" == "latest" ]]; then
        base_url="https://github.com/XTLS/Xray-core/releases/latest/download"
    else
        base_url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_TAG}"
    fi
    dgst_url="${base_url}/${ZIP_NAME}.dgst"
    if ! dgst=$(timeout 25 curl -fsL --connect-timeout 10 --max-time 20 "$dgst_url" 2>/dev/null); then
        echo "⚠️ 未获取到官方校验文件，跳过完整性校验。"
        return
    fi
    expected=$(printf '%s\n' "$dgst" | grep -iE '^SHA2?-?256' | awk -F'= ' '{print $2}' | tr -d ' \r')
    if [[ -z "$expected" ]]; then
        echo "⚠️ 校验文件格式不符，跳过校验。"
        return
    fi
    actual=$(sha256sum "${ZIP_NAME}" | awk '{print $1}')
    if [[ "$expected" == "$actual" ]]; then
        echo "✅ SHA256 校验通过。"
    else
        echo "❌ 校验不匹配，删除文件并退出。"
        rm -f "${ZIP_NAME}"
        exit 1
    fi
}

extract_zip() {
    local zip="$1" outdir="$2"

    if command -v unzip >/dev/null 2>&1; then
        echo "🔧 使用 unzip 解压..."
        unzip -o "$zip" xray -d "$outdir" >/dev/null
        return $?
    fi

    if command -v python3 >/dev/null 2>&1; then
        echo "🔧 没有 unzip，改用 python3 的 zipfile 模块解压..."
        python3 - "$zip" "$outdir" <<'PYEOF'
import sys, zipfile
zip_path, outdir = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(zip_path) as z:
    z.extract("xray", outdir)
PYEOF
        return $?
    fi

    if command -v bsdtar >/dev/null 2>&1; then
        echo "🔧 没有 unzip/python3，改用 bsdtar 解压..."
        (cd "$outdir" && bsdtar -xf "$OLDPWD/$zip" xray)
        return $?
    fi

    if command -v tar >/dev/null 2>&1 && tar --version 2>/dev/null | grep -qi 'bsdtar\|libarchive'; then
        echo "🔧 没有 unzip/python3，改用支持 zip 的 tar 解压..."
        (cd "$outdir" && tar -xf "$OLDPWD/$zip" xray)
        return $?
    fi

    if command -v jar >/dev/null 2>&1; then
        echo "🔧 没有 unzip/python3/bsdtar，改用 java 自带的 jar 命令解压..."
        (cd "$outdir" && jar xf "$OLDPWD/$zip" xray)
        return $?
    fi

    if command -v busybox >/dev/null 2>&1 && busybox unzip --help >/dev/null 2>&1; then
        echo "🔧 改用 busybox unzip 解压..."
        busybox unzip -o "$zip" xray -d "$outdir" >/dev/null
        return $?
    fi

    return 1
}

download_xray() {
    if [[ -f "$BIN_PATH" ]]; then
        echo "✅ xray 二进制已存在，跳过下载。"
        return
    fi
    local direct_url mirror_url
    if [[ "$XRAY_TAG" == "latest" ]]; then
        direct_url="https://github.com/XTLS/Xray-core/releases/latest/download/${ZIP_NAME}"
    else
        direct_url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_TAG}/${ZIP_NAME}"
    fi
    mirror_url="${GHPROXY_BASE:-}${direct_url}"

    echo "⏳ 下载: ${mirror_url}"
    if ! curl -fL --retry 3 --connect-timeout 15 --max-time 90 -o "${ZIP_NAME}" "$mirror_url"; then
        echo "⚠️ 下载失败或超时（15秒内连不上/90秒内传不完）。"
        if [[ -z "${GHPROXY_BASE:-}" ]]; then
            echo "🔁 尝试改用加速镜像重试一次..."
            rm -f "${ZIP_NAME}"
            if ! curl -fL --retry 3 --connect-timeout 15 --max-time 90 -o "${ZIP_NAME}" "https://ghfast.top/${direct_url}"; then
                echo "❌ 镜像也失败了。可以手动指定其他镜像重试，例如："
                echo "   GHPROXY_BASE=https://gh-proxy.com/ bash $0 $PORT"
                echo "   或者在自己电脑下载好 ${ZIP_NAME} 后手动传到这个目录（$BASE_DIR）再重跑脚本。"
                rm -f "${ZIP_NAME}"
                exit 1
            fi
            echo "✅ 镜像下载成功。"
        else
            rm -f "${ZIP_NAME}"
            exit 1
        fi
    fi
    verify_checksum

    if ! extract_zip "${ZIP_NAME}" "${BASE_DIR}"; then
        echo "❌ 没找到任何可用的解压工具（试过 unzip / python3 / bsdtar / tar / jar / busybox），"
        echo "   而且你没有 root 权限装新的。"
        exit 1
    fi

    if [[ ! -f "$BIN_PATH" ]]; then
        echo "❌ 解压后没找到 ${BIN_PATH}，压缩包内文件名可能和预期不一致。"
        exit 1
    fi
    chmod +x "$BIN_PATH"
    echo "✅ xray 下载解压完成: $BIN_PATH"
}
download_xray

# ---------- REALITY 密钥 / shortId：复用已保存的，没有才生成 ----------
REALITY_KEY_FILE="reality_key.json"
# 额外的 shortId，逗号分隔，比如给不同设备各发一个，互不影响：
#   REALITY_EXTRA_SHORT_IDS=aabbccdd,11223344
# 每个必须是 0~16 位的十六进制字符串。主 shortId（存在 reality_key.json 里的
# 那个）始终保留，这里只是往数组里再加几个，客户端链接里默认展示主 shortId。
REALITY_EXTRA_SHORT_IDS="${REALITY_EXTRA_SHORT_IDS:-}"
generate_reality_identity() {
    if [[ -f "$REALITY_KEY_FILE" ]]; then
        REALITY_PRIVATE_KEY=$(grep -o '"private":"[^"]*"' "$REALITY_KEY_FILE" | cut -d'"' -f4)
        REALITY_PUBLIC_KEY=$(grep -o '"public":"[^"]*"' "$REALITY_KEY_FILE" | cut -d'"' -f4)
        REALITY_SHORT_ID=$(grep -o '"shortId":"[^"]*"' "$REALITY_KEY_FILE" | cut -d'"' -f4)
        echo "✅ 复用已保存的 REALITY 密钥/shortId（$REALITY_KEY_FILE）"
        return
    fi
    local keys_out
    keys_out=$("$BIN_PATH" x25519)
    REALITY_PRIVATE_KEY=$(printf '%s\n' "$keys_out" | grep -i 'priv' | awk -F': ' '{print $2}' | tr -d ' \r')
    REALITY_PUBLIC_KEY=$(printf '%s\n' "$keys_out" | grep -i 'pub' | awk -F': ' '{print $2}' | tr -d ' \r')
    if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
        echo "❌ 生成 REALITY 密钥对失败，xray x25519 输出格式异常，原始输出如下："
        echo "$keys_out"
        exit 1
    fi
    REALITY_SHORT_ID=$(openssl rand -hex 8)
    cat > "$REALITY_KEY_FILE" <<JSONEOF
{"private":"${REALITY_PRIVATE_KEY}","public":"${REALITY_PUBLIC_KEY}","shortId":"${REALITY_SHORT_ID}"}
JSONEOF
    chmod 600 "$REALITY_KEY_FILE"
    echo "🔑 已生成新的 REALITY 密钥对 + shortId，保存于 $REALITY_KEY_FILE"
    echo "⚠️ 这个文件必须妥善保存：换了私钥，之前发出去的所有客户端链接全部失效。"
}
generate_reality_identity

# 把主 shortId 和 REALITY_EXTRA_SHORT_IDS 拼成 JSON 数组，供 config.json 使用
build_short_ids_json() {
    local json="\"${REALITY_SHORT_ID}\""
    if [[ -n "$REALITY_EXTRA_SHORT_IDS" ]]; then
        local id
        IFS=',' read -ra _ids <<< "$REALITY_EXTRA_SHORT_IDS"
        for id in "${_ids[@]}"; do
            id=$(printf '%s' "$id" | tr -d '[:space:]')
            [[ -n "$id" ]] && json="${json}, \"${id}\""
        done
    fi
    echo "$json"
}
REALITY_SHORT_IDS_JSON=$(build_short_ids_json)


# ---------- 可选自检：REALITY_DEST 是否满足 TLS1.3 + HTTP/2 ----------
check_reality_dest() {
    if ! command -v openssl >/dev/null 2>&1; then
        echo "ℹ️ 没有 openssl，跳过 REALITY_DEST 自检。"
        return
    fi
    local host="${REALITY_DEST%%:*}" port="${REALITY_DEST##*:}"
    echo "🔎 自检 REALITY_DEST=${REALITY_DEST} 是否支持 TLS1.3 + h2 ..."
    local out
    out=$(echo -e "GET / HTTP/1.1\r\nHost: ${host}\r\nConnection: close\r\n\r\n" | \
        timeout 12 openssl s_client -connect "${host}:${port}" -servername "$host" \
        -tls1_3 -alpn h2 -quiet 2>&1 || true)
    if printf '%s' "$out" | grep -qi 'ALPN protocol.*h2\|Negotiated TLS1.3\|TLSv1.3'; then
        echo "✅ 看起来支持 TLS1.3（具体 ALPN 协商情况建议你自己再用真实客户端连一次确认）。"
    else
        echo "⚠️ 没有明确探测到 TLS1.3/h2 支持，REALITY_DEST 换一个更保险，"
        echo "   或者手动执行下面命令自己确认："
        echo "   openssl s_client -connect ${host}:${port} -servername ${host} -tls1_3 -alpn h2"
    fi
}
check_reality_dest

# ---------- 写 xray 配置 ----------
write_xray_config() {
if [[ "$REALITY_NETWORK" == "tcp" ]]; then
cat > "${BASE_DIR}/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${CLIENT_UUID}", "flow": "${REALITY_FLOW}" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "sockopt": {
          "tcpFastOpen": true,
          "tcpKeepAliveInterval": 25
        },
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": [ "${REALITY_SNI}" ],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": [ ${REALITY_SHORT_IDS_JSON} ]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF
else
cat > "${BASE_DIR}/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${CLIENT_UUID}" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "sockopt": {
          "tcpFastOpen": true,
          "tcpKeepAliveInterval": 25
        },
        "xhttpSettings": {
          "path": "${XHTTP_PATH}",
          "mode": "${XHTTP_MODE}"
        },
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": [ "${REALITY_SNI}" ],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": [ ${REALITY_SHORT_IDS_JSON} ]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF
fi
    echo "✅ 已写入 xray config.json（监听 0.0.0.0:${PORT}，REALITY，借用身份=${REALITY_SNI}）。"
}
write_xray_config

# ---------- 打印连接信息 ----------
print_connection_info() {
    local addr="$CONNECT_ADDR"
    if [[ -z "$addr" ]]; then
        addr=$(timeout 8 curl -fsSL --connect-timeout 5 --max-time 6 https://ifconfig.me 2>/dev/null || true)
        if [[ -z "$addr" ]]; then
            addr=$(timeout 8 curl -fsSL --connect-timeout 5 --max-time 6 https://icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)
        fi
    fi

    echo "🎉 配置完成，即将启动！"
    echo "=========================================================================="
    echo "📋 连接信息:"
    echo "   🔌 端口: ${PORT}"
    echo "   🔑 UUID: ${CLIENT_UUID}（保存于 ${BASE_DIR}/${UUID_FILE}）"
    echo "   🎭 SNI（伪装域名）: ${REALITY_SNI}"
    echo "   🗝️ 公钥(pbk): ${REALITY_PUBLIC_KEY}"
    echo "   🆔 shortId(sid): ${REALITY_SHORT_ID}"
    if [[ -n "$REALITY_EXTRA_SHORT_IDS" ]]; then
        echo "   🆔 额外 shortId（可分发给不同设备）: ${REALITY_EXTRA_SHORT_IDS}"
    fi
    echo "   📡 传输: ${REALITY_NETWORK}$( [[ -n "$REALITY_FLOW" ]] && echo "  flow=${REALITY_FLOW}" )"
    echo "   🔒 私钥等敏感信息保存于 ${BASE_DIR}/${REALITY_KEY_FILE}（别泄露）"
    echo ""
    if [[ -z "$addr" ]]; then
        echo "⚠️ 没能自动探测到公网 IP，下面链接里的 地址部分 需要你自己手动替换成"
        echo "   服务器的公网 IP 或者你自己的域名（不需要这个域名有证书）。"
        addr="替换成你的服务器IP或域名"
    fi
    echo "📱 节点链接:"
    if [[ "$REALITY_NETWORK" == "tcp" ]]; then
        echo "vless://${CLIENT_UUID}@${addr}:${PORT}?encryption=none&security=reality&sni=${REALITY_SNI}&fp=${REALITY_FINGERPRINT}&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&flow=${REALITY_FLOW}#Vless-REALITY"
    else
        echo "vless://${CLIENT_UUID}@${addr}:${PORT}?encryption=none&security=reality&sni=${REALITY_SNI}&fp=${REALITY_FINGERPRINT}&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=xhttp&path=${XHTTP_PATH}&mode=${XHTTP_MODE}#Vless-REALITY-XHTTP"
    fi
    echo "=========================================================================="
    echo "⚠️ 面板/控制台关闭或断开后进程是否存活，取决于你用的面板机制"
    echo "   （很多面板本身就是靠盯着这个前台进程来保活/重启的，属于正常现象）。"
}
print_connection_info

# ---------- BBR 状态自检（只读，不修改内核参数） ----------
check_bbr() {
    local ccalgo
    if [[ ! -r /proc/sys/net/ipv4/tcp_congestion_control ]]; then
        echo "ℹ️ 无法读取拥塞控制算法（/proc/sys 不可读，容器限制），跳过 BBR 检测。"
        return
    fi
    ccalgo=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "")
    if [[ "$ccalgo" == "bbr" ]]; then
        echo "✅ 当前拥塞控制算法已经是 bbr（宿主机内核已开启，容器直接受益，无需你操作）。"
    else
        echo "ℹ️ 当前拥塞控制算法是「${ccalgo:-未知}」，不是 bbr（宿主机内核级设置，容器内通常改不了）。"
    fi
}
check_bbr

echo "🚀 启动 Xray..."
exec "$BIN_PATH" run -c "${BASE_DIR}/config.json"
