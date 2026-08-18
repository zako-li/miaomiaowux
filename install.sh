#!/bin/bash
# ============================================================================
# 妙妙屋X 开心版 —— 面板一键安装 / 更新 / 卸载
#
#   安装:  curl -fsSL https://raw.githubusercontent.com/zako-li/miaomiaowux/main/install.sh | bash
#   更新:  curl -fsSL https://raw.githubusercontent.com/zako-li/miaomiaowux/main/install.sh | bash -s update
#          （面板里「系统设置 → 检查更新」也能直接升级，这条是面板打不开时的兜底）
#   卸载:  curl -fsSL https://raw.githubusercontent.com/zako-li/miaomiaowux/main/install.sh | bash -s uninstall
#
# 常用参数（放在命令最后，例：... | bash -s -- --port 8080）:
#   --port <端口>        面板监听端口，默认 12889（仅首次安装生效）
#   --data-dir <目录>    数据目录，默认 /etc/mmwx/data（仅首次安装生效）
#   --version <tag>      指定 release 的 tag，例 mmwx；默认自动找
#   --binary <文件>      直接用本地二进制安装，不联网下载
#
# 可选环境变量:
#   MMWX_GH_PROXY=https://ghproxy.example/    GitHub 加速前缀（国内网络用）
#   MMWX_REPO=owner/repo                      换成你自己的仓库
# ============================================================================
set -euo pipefail

REPO="${MMWX_REPO:-zako-li/miaomiaowux}"
# 面板 release 的 tag：固定用 mmwx（滚动 release，版本号写在 release 名字里）。
# 也兼容「每版一个 tag」的 mmwx-v0.4.8-beta.18 写法。mmwx-agent* 不会被误命中。
TAG_MATCH="^(mmwx|mmwx-v.*)$"
ASSET_BASE="mmwx-linux"       # 资产名 mmwx-linux-amd64 / mmwx-linux-arm64
BIN_PATH="/usr/local/bin/mmwx"
UNIT_PATH="/etc/systemd/system/mmwx.service"
SERVICE="mmwx"

ACTION="install"
PORT=""
DATA_DIR=""
WANT_TAG=""
LOCAL_BINARY=""

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
info() { echo "${BLUE}[INFO]${NC} $*"; }
ok()   { echo "${GREEN}[ OK ]${NC} $*"; }
warn() { echo "${YELLOW}[WARN]${NC} $*"; }
die()  { echo "${RED}[FAIL]${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------- 参数解析
while [ $# -gt 0 ]; do
    case "$1" in
        install|update|upgrade|uninstall|remove) ACTION="$1"; shift ;;
        --port)      PORT="${2:-}"; shift 2 ;;
        --data-dir)  DATA_DIR="${2:-}"; shift 2 ;;
        --version)   WANT_TAG="${2:-}"; shift 2 ;;
        --binary)    LOCAL_BINARY="${2:-}"; shift 2 ;;
        -h|--help)   sed -n '2,22p' "$0"; exit 0 ;;
        *)           die "未知参数: $1（-h 看用法）" ;;
    esac
done
[ "$ACTION" = "upgrade" ] && ACTION="update"
[ "$ACTION" = "remove" ] && ACTION="uninstall"

[ "$(id -u)" -eq 0 ] || die "请用 root 运行（前面加 sudo）"

# ---------------------------------------------------------------- 基础工具
need_cmd() {
    command -v "$1" >/dev/null 2>&1 && return 0
    info "缺少 $1，尝试自动安装..."
    if   command -v apt-get >/dev/null 2>&1; then apt-get update -qq >/dev/null 2>&1 || true; DEBIAN_FRONTEND=noninteractive apt-get install -y "$1" >/dev/null
    elif command -v dnf     >/dev/null 2>&1; then dnf install -y "$1" >/dev/null
    elif command -v yum     >/dev/null 2>&1; then yum install -y "$1" >/dev/null
    elif command -v apk     >/dev/null 2>&1; then apk add --no-cache "$1" >/dev/null
    elif command -v pacman  >/dev/null 2>&1; then pacman -Sy --noconfirm "$1" >/dev/null
    elif command -v zypper  >/dev/null 2>&1; then zypper -n install "$1" >/dev/null
    else die "无法识别包管理器，请手动安装 $1 后重试"; fi
    command -v "$1" >/dev/null 2>&1 || die "$1 安装失败"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) die "不支持的架构: $(uname -m)（只提供 amd64 / arm64）" ;;
    esac
}

gh_url() { # gh_url <完整github地址> -> 套上可选加速前缀
    local proxy="${MMWX_GH_PROXY:-}"
    if [ -n "$proxy" ]; then echo "${proxy%/}/$1"; else echo "$1"; fi
}

# 从 Releases 里挑出面板那条（tag = mmwx，或老写法 mmwx-v*）。GitHub 返回按时间倒序，取第一个即可。
resolve_latest_tag() {
    local api="https://api.github.com/repos/${REPO}/releases?per_page=100"
    curl -fsSL --connect-timeout 15 --max-time 60 -H 'Accept: application/vnd.github+json' "$api" 2>/dev/null \
        | grep -o '"tag_name":[[:space:]]*"[^"]*"' \
        | sed 's/.*"tag_name":[[:space:]]*"//; s/"$//' \
        | grep -E "$TAG_MATCH" \
        | head -n 1
}

download_binary() { # download_binary <tag> <arch> <输出路径>
    local tag="$1" arch="$2" out="$3"
    local url
    url="$(gh_url "https://github.com/${REPO}/releases/download/${tag}/${ASSET_BASE}-${arch}")"
    info "下载 ${tag} (${arch})"
    info "  $url"
    curl -fL --progress-bar --connect-timeout 20 --retry 3 -o "$out" "$url" \
        || die "下载失败。可以 --version 指定别的 tag，或设 MMWX_GH_PROXY 走加速，或 --binary 用本地文件"
    [ -s "$out" ] || die "下载到的文件是空的"
}

current_version() {
    [ -x "$BIN_PATH" ] || return 1
    "$BIN_PATH" --version 2>/dev/null | head -1 || return 1
}

# ---------------------------------------------------------------- 卸载
if [ "$ACTION" = "uninstall" ]; then
    info "停止并禁用服务..."
    systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
    rm -f "$UNIT_PATH"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -f "$BIN_PATH"
    ok "面板已卸载"
    echo ""
    warn "数据目录没有删除，确认不要了再手动清理，例如："
    echo "    rm -rf /etc/mmwx"
    exit 0
fi

# ---------------------------------------------------------------- 安装 / 更新
need_cmd curl

ARCH="$(detect_arch)"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
NEW_BIN="$STAGING/mmwx"

if [ -n "$LOCAL_BINARY" ]; then
    [ -f "$LOCAL_BINARY" ] || die "找不到本地二进制: $LOCAL_BINARY"
    info "使用本地二进制: $LOCAL_BINARY（不联网）"
    cp "$LOCAL_BINARY" "$NEW_BIN"
else
    TAG="$WANT_TAG"
    if [ -z "$TAG" ]; then
        info "查询最新版本..."
        TAG="$(resolve_latest_tag || true)"
        [ -n "$TAG" ] || die "没查到面板的 Release（tag 应为 mmwx）。可能是 GitHub API 限流或还没发版；也可以 --version <tag> 直接指定"
        ok "最新版本: $TAG"
    fi
    download_binary "$TAG" "$ARCH" "$NEW_BIN"
fi
chmod 0755 "$NEW_BIN"

if [ "$ACTION" = "update" ] && [ ! -x "$BIN_PATH" ]; then
    warn "当前没装过，按首次安装处理"
    ACTION="install"
fi

RUNNING=0
systemctl is-active --quiet "$SERVICE" && RUNNING=1

if [ "$RUNNING" = "1" ]; then
    info "停止 $SERVICE ..."
    systemctl stop "$SERVICE"
fi

# 原地替换，失败自动回滚
if [ -f "$BIN_PATH" ]; then cp -p "$BIN_PATH" "$STAGING/mmwx.old"; fi
if ! install -m 0755 "$NEW_BIN" "$BIN_PATH.new" || ! mv -f "$BIN_PATH.new" "$BIN_PATH"; then
    rm -f "$BIN_PATH.new"
    if [ -f "$STAGING/mmwx.old" ]; then cp -p "$STAGING/mmwx.old" "$BIN_PATH"; fi
    [ "$RUNNING" = "1" ] && systemctl start "$SERVICE" || true
    die "安装二进制失败，已恢复原文件"
fi
ok "二进制已安装到 $BIN_PATH"

# systemd 单元只在首次安装时写，更新不覆盖用户改过的配置
if [ ! -f "$UNIT_PATH" ]; then
    PORT="${PORT:-12889}"
    DATA_DIR="${DATA_DIR:-/etc/mmwx/data}"
    mkdir -p "$DATA_DIR" "$DATA_DIR/agent-bin"
    # 安装时设过加速前缀就写进服务里，面板自更新 / 下发 Agent 也能沿用
    EXTRA_ENV=""
    if [ -n "${MMWX_GH_PROXY:-}" ]; then
        EXTRA_ENV="Environment=\"MMWX_GH_PROXY=${MMWX_GH_PROXY}\"
"
        info "已把 MMWX_GH_PROXY 写进服务配置"
    fi
    info "写入 systemd 单元 $UNIT_PATH （端口 $PORT，数据目录 $DATA_DIR）"
    cat > "$UNIT_PATH" <<EOF
[Unit]
Description=MiaomiaowuX Panel
After=network.target

[Service]
Type=simple
ExecStart=${BIN_PATH}
Environment="PORT=${PORT}"
Environment="MMWX_DATA_DIR=${DATA_DIR}"
${EXTRA_ENV}Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE" >/dev/null 2>&1 || true
else
    [ -n "$PORT" ] && warn "已存在 $UNIT_PATH，--port 被忽略（要改端口就直接编辑该文件）"
    [ -n "$DATA_DIR" ] && warn "已存在 $UNIT_PATH，--data-dir 被忽略"
    PORT="$(sed -n 's/.*PORT=\([0-9]*\).*/\1/p' "$UNIT_PATH" | head -1)"
    PORT="${PORT:-12889}"
    DATA_DIR="$(sed -n 's/.*MMWX_DATA_DIR=\([^"]*\).*/\1/p' "$UNIT_PATH" | head -1)"
    DATA_DIR="${DATA_DIR:-/etc/mmwx/data}"
    systemctl daemon-reload
fi

info "启动服务..."
systemctl start "$SERVICE"

sleep 2
if ! systemctl is-active --quiet "$SERVICE"; then
    die "启动失败，看日志：journalctl -u ${SERVICE} -n 50 --no-pager"
fi

echo ""
ok "完成！"
echo ""
echo "  面板地址 : http://<本机IP>:${PORT}"
echo "  版本     : $(current_version || echo '未知')"
echo "  数据目录 : ${DATA_DIR}"
echo "  服务管理 : systemctl {status|restart|stop} ${SERVICE}"
echo ""
echo "  以后更新 : 面板里「系统设置 → 检查更新」直接点，或者跑"
echo "             curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | sudo bash -s update"
echo ""
