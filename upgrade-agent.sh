#!/bin/bash
# ============================================================================
# 妙妙屋X 开心版 —— 子服务器 Agent 升级脚本
#
# 只做一件事：换掉 /usr/local/bin/mmw-agent 这个二进制，然后重启服务。
# 配置（/etc/mmw-agent/config.yaml）、systemd/OpenRC 单元、xray 都不动。
#
#   curl -fsSL https://raw.githubusercontent.com/zako-li/miaomiaowux/main/upgrade-agent.sh | bash
#
# 参数:
#   --version <tag>   指定 release 的 tag，例 mmwx-agent；默认自动找
#   --binary <文件>   直接用本地二进制，不联网下载
#
# 环境变量:
#   MMWX_GH_PROXY=https://ghproxy.example/   GitHub 加速前缀
#   MMWX_REPO=owner/repo                     换成你自己的仓库
#
# 首次安装 Agent 请在面板「添加服务器」里拿一键命令，那个脚本会连带写配置和服务。
# ============================================================================
set -euo pipefail

REPO="${MMWX_REPO:-zako-li/miaomiaowux}"
# Agent release 的 tag：固定用 mmwx-agent；也兼容 mmwx-agent-v<版本> 的写法。
TAG_MATCH="^(mmwx-agent|mmwx-agent-v.*)$"
ASSET_BASE="mmwx-agent-linux"
BIN_PATH="/usr/local/bin/mmw-agent"

WANT_TAG=""
LOCAL_BINARY=""

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
info() { echo "${BLUE}[INFO]${NC} $*"; }
ok()   { echo "${GREEN}[ OK ]${NC} $*"; }
warn() { echo "${YELLOW}[WARN]${NC} $*"; }
die()  { echo "${RED}[FAIL]${NC} $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --version) WANT_TAG="${2:-}"; shift 2 ;;
        --binary)  LOCAL_BINARY="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *)         die "未知参数: $1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "请用 root 运行（前面加 sudo）"
[ -f "$BIN_PATH" ] || die "本机没装 Agent（找不到 $BIN_PATH）。首次安装请用面板「添加服务器」给的命令。"
command -v curl >/dev/null 2>&1 || die "请先安装 curl"

case "$(uname -m)" in
    x86_64|amd64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) die "不支持的架构: $(uname -m)" ;;
esac

gh_url() {
    local proxy="${MMWX_GH_PROXY:-}"
    if [ -n "$proxy" ]; then echo "${proxy%/}/$1"; else echo "$1"; fi
}

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
NEW_BIN="$STAGING/mmw-agent"

if [ -n "$LOCAL_BINARY" ]; then
    [ -f "$LOCAL_BINARY" ] || die "找不到本地二进制: $LOCAL_BINARY"
    info "使用本地二进制: $LOCAL_BINARY（不联网）"
    cp "$LOCAL_BINARY" "$NEW_BIN"
else
    TAG="$WANT_TAG"
    if [ -z "$TAG" ]; then
        info "查询最新 Agent 版本..."
        TAG="$(curl -fsSL --connect-timeout 15 --max-time 60 -H 'Accept: application/vnd.github+json' \
                 "https://api.github.com/repos/${REPO}/releases?per_page=100" 2>/dev/null \
               | grep -o '"tag_name":[[:space:]]*"[^"]*"' \
               | sed 's/.*"tag_name":[[:space:]]*"//; s/"$//' \
               | grep -E "$TAG_MATCH" | head -n 1 || true)"
        [ -n "$TAG" ] || die "没查到 Agent 的 Release（tag 应为 mmwx-agent）。可能是 GitHub API 限流；也可以 --version <tag> 直接指定"
        ok "最新版本: $TAG"
    fi
    URL="$(gh_url "https://github.com/${REPO}/releases/download/${TAG}/${ASSET_BASE}-${ARCH}")"
    info "下载 $URL"
    curl -fL --progress-bar --connect-timeout 20 --retry 3 -o "$NEW_BIN" "$URL" \
        || die "下载失败。可设 MMWX_GH_PROXY 走加速，或 --binary 用本地文件"
    [ -s "$NEW_BIN" ] || die "下载到的文件是空的"
fi
chmod 0755 "$NEW_BIN"

# 认出当前用的是哪套 init，升级完照原样拉起来
STOP_CMD=""; START_CMD=""
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^mmw-agent\.service'; then
    STOP_CMD="systemctl stop mmw-agent"; START_CMD="systemctl start mmw-agent"
elif command -v rc-service >/dev/null 2>&1 && [ -f /etc/init.d/mmw-agent ]; then
    STOP_CMD="rc-service mmw-agent stop"; START_CMD="rc-service mmw-agent start"
else
    warn "没找到 systemd / OpenRC 服务，按「supervisor 脚本 + 直接杀进程」处理"
    STOP_CMD="pkill -x mmw-agent || true"; START_CMD=""
fi

info "停止 Agent..."
eval "$STOP_CMD" >/dev/null 2>&1 || true
sleep 1

cp -p "$BIN_PATH" "$STAGING/mmw-agent.old"
if ! install -m 0755 "$NEW_BIN" "$BIN_PATH.new" || ! mv -f "$BIN_PATH.new" "$BIN_PATH"; then
    rm -f "$BIN_PATH.new"
    cp -p "$STAGING/mmw-agent.old" "$BIN_PATH"
    [ -n "$START_CMD" ] && eval "$START_CMD" >/dev/null 2>&1 || true
    die "替换二进制失败，已回滚"
fi
ok "二进制已更新"

if [ -n "$START_CMD" ]; then
    info "启动 Agent..."
    eval "$START_CMD"
    sleep 2
    if command -v systemctl >/dev/null 2>&1 && [ "$START_CMD" = "systemctl start mmw-agent" ]; then
        if systemctl is-active --quiet mmw-agent; then
            ok "Agent 已重启"
        else
            warn "启动异常，回滚到旧版本"
            cp -p "$STAGING/mmw-agent.old" "$BIN_PATH"
            systemctl start mmw-agent || true
            die "升级失败已回滚，看日志：journalctl -u mmw-agent -n 50 --no-pager"
        fi
    else
        ok "Agent 已重启"
    fi
else
    warn "没有服务管理器，supervisor 脚本会在几秒内自动把新二进制拉起来"
fi

echo ""
ok "完成。回主控面板看一下该服务器是否恢复在线即可。"
