```bash
#!/usr/bin/env bash
set -euo pipefail

# =========================
# CPA 一键更新脚本
# =========================

SERVICE="cpa"
INSTALL_DIR="/etc/cpa"
REPO="router-for-me/CLIProxyAPI"

TMP_DIR="/tmp/cpa-update-$$"
ARCHIVE="$TMP_DIR/cpa.tar.gz"
NEW_BIN="$TMP_DIR/new-bin"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# 必须 root
if [[ "${EUID}" -ne 0 ]]; then
    echo "请使用 root 运行：sudo $0"
    exit 1
fi

# 检查依赖
for cmd in curl tar systemctl grep sed awk head; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "错误：缺少命令 $cmd"
        exit 1
    fi
done

mkdir -p "$TMP_DIR"

echo "========================================"
echo "       CPA 一键更新"
echo "========================================"

# ----------------------------------------
# 1. 获取当前 CPA 本体路径
# ----------------------------------------
CPA_BIN="$(systemctl cat "$SERVICE" 2>/dev/null \
    | sed -n 's/.*ExecStart=.*\('"$INSTALL_DIR"'\/[^ ;"]*\).*/\1/p' \
    | head -n 1 || true)"

# 如果 systemd 文件没找到，则尝试自动寻找可执行文件
if [[ -z "$CPA_BIN" ]]; then
    CPA_BIN="$(find "$INSTALL_DIR" -maxdepth 1 -type f -perm -111 \
        \( -name 'cli-proxy-api' -o -name 'CLIProxyAPI' \) \
        | head -n 1 || true)"
fi

if [[ -z "$CPA_BIN" ]]; then
    echo "错误：无法找到 CPA 本体"
    echo "请检查 $SERVICE 的 ExecStart"
    exit 1
fi

if [[ ! -f "$CPA_BIN" ]]; then
    echo "错误：CPA 本体不存在：$CPA_BIN"
    exit 1
fi

BIN_NAME="$(basename "$CPA_BIN")"

echo "安装目录 : $INSTALL_DIR"
echo "本体文件 : $CPA_BIN"
echo "服务名称 : $SERVICE"
echo "架构     : $(uname -m)"
echo

# ----------------------------------------
# 2. 判断 CPU 架构
# ----------------------------------------
case "$(uname -m)" in
    x86_64|amd64)
        RELEASE_ARCH="amd64"
        ;;
    aarch64|arm64)
        RELEASE_ARCH="arm64"
        ;;
    armv7l|armv7)
        RELEASE_ARCH="armv7"
        ;;
    *)
        echo "错误：暂不支持的架构：$(uname -m)"
        exit 1
        ;;
esac

# ----------------------------------------
# 3. 获取最新 Release 下载地址
# ----------------------------------------
echo "[1/5] 获取最新版..."

API_URL="https://api.github.com/repos/${REPO}/releases/latest"

DOWNLOAD_URL="$(
    curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        "$API_URL" \
    | grep -oE 'https://[^"]+_linux_'"$RELEASE_ARCH"'\.tar\.gz' \
    | grep -v 'no-plugin' \
    | head -n 1 || true
)"

if [[ -z "$DOWNLOAD_URL" ]]; then
    echo "错误：没有找到对应架构的最新版 Linux 发布包"
    echo "仓库：$REPO"
    echo "架构：linux_$RELEASE_ARCH"
    exit 1
fi

echo "下载地址：$DOWNLOAD_URL"
echo

# ----------------------------------------
# 4. 下载最新版
# ----------------------------------------
echo "[2/5] 下载最新版..."

curl -fL --retry 3 --retry-delay 2 \
    "$DOWNLOAD_URL" \
    -o "$ARCHIVE"

echo "下载完成"
echo

# ----------------------------------------
# 5. 从压缩包中只提取 CPA 本体
# ----------------------------------------
echo "[3/5] 提取 CPA 本体..."

# 优先寻找与当前二进制同名的文件
MEMBER="$(
    tar -tzf "$ARCHIVE" \
    | sed 's#^\./##' \
    | grep -E "(^|/)$BIN_NAME$" \
    | head -n 1 || true
)"

# 如果名字发生变化，兼容官方常见名称
if [[ -z "$MEMBER" ]]; then
    MEMBER="$(
        tar -tzf "$ARCHIVE" \
        | sed 's#^\./##' \
        | grep -E '(^|/)(cli-proxy-api|CLIProxyAPI)$' \
        | head -n 1 || true
    )"
fi

if [[ -z "$MEMBER" ]]; then
    echo "错误：压缩包中没有找到 CPA 本体"
    echo
    echo "压缩包内容："
    tar -tzf "$ARCHIVE"
    exit 1
fi

echo "本体文件：$MEMBER"

tar -xOzf "$ARCHIVE" "$MEMBER" > "$NEW_BIN"

chmod +x "$NEW_BIN"

# 检查是不是 ELF
if ! file "$NEW_BIN" | grep -q ELF; then
    echo "错误：提取出的文件不是有效 ELF 可执行文件"
    exit 1
fi

echo "本体提取完成"
echo

# ----------------------------------------
# 6. 停止服务
# ----------------------------------------
echo "[4/5] 停止 CPA..."

systemctl stop "$SERVICE"

# 等待服务真正停止
for _ in {1..20}; do
    if ! systemctl is-active --quiet "$SERVICE"; then
        break
    fi
    sleep 0.5
done

if systemctl is-active --quiet "$SERVICE"; then
    echo "错误：CPA 服务无法停止"
    exit 1
fi

echo "CPA 已停止"
echo

# ----------------------------------------
# 7. 替换本体
# ----------------------------------------
echo "替换本体..."

# 使用 mv 原子替换
mv -f "$NEW_BIN" "$CPA_BIN"

echo "本体替换完成"
echo

# ----------------------------------------
# 8. 启动服务
# ----------------------------------------
echo "[5/5] 启动 CPA..."

systemctl start "$SERVICE"

sleep 2

if systemctl is-active --quiet "$SERVICE"; then
    echo
    echo "========================================"
    echo "        CPA 更新成功"
    echo "========================================"
    echo
    systemctl --no-pager --full status "$SERVICE"
else
    echo
    echo "========================================"
    echo "        CPA 启动失败"
    echo "========================================"
    echo
    systemctl --no-pager --full status "$SERVICE"
    exit 1
fi
```
