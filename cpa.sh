```bash
#!/usr/bin/env bash

set -u

SERVICE="cpa"
INSTALL_DIR="/etc/cpa"
CPA_BIN="${INSTALL_DIR}/cli-proxy-api"
REPO="router-for-me/CLIProxyAPI"

TMP_DIR="/tmp/cpa-update-$$"
ARCHIVE="${TMP_DIR}/release.tar.gz"
EXTRACT_DIR="${TMP_DIR}/extract"
BACKUP_BIN="${TMP_DIR}/cli-proxy-api.backup"

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

echo "========================================"
echo "       CPA 一键更新"
echo "========================================"

# 检查 root
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 运行"
    exit 1
fi

# 检查依赖
for cmd in curl tar grep cut head find systemctl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "错误：缺少必要命令：$cmd"
        exit 1
    fi
done

# 检查安装目录和本体
if [ ! -d "$INSTALL_DIR" ]; then
    echo "错误：安装目录不存在：$INSTALL_DIR"
    exit 1
fi

if [ ! -f "$CPA_BIN" ]; then
    echo "错误：CPA 本体不存在：$CPA_BIN"
    exit 1
fi

mkdir -p "$TMP_DIR" "$EXTRACT_DIR"

echo "安装目录 : $INSTALL_DIR"
echo "本体文件 : $CPA_BIN"
echo "服务名称 : $SERVICE"
echo "架构     : $(uname -m)"
echo

# 判断 CPU 架构
case "$(uname -m)" in
    x86_64)
        RELEASE_ARCH="amd64"
        ;;
    aarch64)
        RELEASE_ARCH="aarch64"
        ;;
    *)
        echo "错误：暂不支持的 CPU 架构：$(uname -m)"
        exit 1
        ;;
esac

# 获取最新版
echo "[1/5] 获取最新版..."

RELEASE_JSON="${TMP_DIR}/release.json"

if ! curl -fsSL \
    --retry 3 \
    --retry-delay 2 \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}/releases/latest" \
    -o "$RELEASE_JSON"; then

    echo "错误：无法获取 GitHub 最新 Release"
    exit 1
fi

VERSION="$(
    grep -m1 '"tag_name":' "$RELEASE_JSON" \
    | cut -d '"' -f 4
)"

if [ -z "$VERSION" ]; then
    echo "错误：无法获取最新版本号"
    exit 1
fi

# 只匹配默认 Linux 包
DOWNLOAD_URL="$(
    grep '"browser_download_url":' "$RELEASE_JSON" \
    | cut -d '"' -f 4 \
    | grep -E "_linux_${RELEASE_ARCH}\.tar\.gz$" \
    | head -n 1
)"

if [ -z "$DOWNLOAD_URL" ]; then
    echo "错误：没有找到默认 Linux ${RELEASE_ARCH} 发布包"
    echo "版本：$VERSION"
    exit 1
fi

echo "最新版本 : $VERSION"
echo "下载地址 : $DOWNLOAD_URL"
echo

# 下载
echo "[2/5] 下载最新版..."

if ! curl -fL \
    --retry 3 \
    --retry-delay 2 \
    --connect-timeout 15 \
    "$DOWNLOAD_URL" \
    -o "$ARCHIVE"; then

    echo "错误：下载失败"
    exit 1
fi

if [ ! -s "$ARCHIVE" ]; then
    echo "错误：下载文件为空"
    exit 1
fi

echo "下载完成"
echo

# 停止服务
echo "[3/5] 停止 CPA..."

if ! systemctl stop "$SERVICE"; then
    echo "错误：无法停止服务 $SERVICE"
    exit 1
fi

for i in 1 2 3 4 5 6 7 8 9 10; do
    if ! systemctl is-active --quiet "$SERVICE"; then
        break
    fi
    sleep 1
done

if systemctl is-active --quiet "$SERVICE"; then
    echo "错误：CPA 服务仍在运行，停止失败"
    exit 1
fi

echo "CPA 已停止"
echo

# 解压
echo "[4/5] 解压 CPA 本体..."

if ! tar -xzf "$ARCHIVE" -C "$EXTRACT_DIR"; then
    echo "错误：解压失败"
    exit 1
fi

NEW_BIN="$(
    find "$EXTRACT_DIR" \
        -type f \
        -name "cli-proxy-api" \
        -print \
        | head -n 1
)"

if [ -z "$NEW_BIN" ]; then
    echo "错误：压缩包中没有找到 cli-proxy-api"
    echo
    echo "压缩包内容："
    tar -tzf "$ARCHIVE"
    exit 1
fi

if [ ! -s "$NEW_BIN" ]; then
    echo "错误：提取出来的 cli-proxy-api 为空"
    exit 1
fi

chmod 755 "$NEW_BIN"

echo "找到本体：$NEW_BIN"

# 备份旧版本
if ! cp -a "$CPA_BIN" "$BACKUP_BIN"; then
    echo "错误：无法备份当前本体"
    exit 1
fi

# 替换
if ! cp -f "$NEW_BIN" "$CPA_BIN"; then
    echo "错误：替换 CPA 本体失败"
    cp -f "$BACKUP_BIN" "$CPA_BIN" 2>/dev/null || true
    systemctl start "$SERVICE" 2>/dev/null || true
    exit 1
fi

chmod 755 "$CPA_BIN"

echo "本体替换完成"
echo

# 启动
echo "[5/5] 启动 CPA..."

if ! systemctl start "$SERVICE"; then
    echo
    echo "新版本启动失败，正在回滚..."

    systemctl stop "$SERVICE" 2>/dev/null || true

    if cp -f "$BACKUP_BIN" "$CPA_BIN"; then
        chmod 755 "$CPA_BIN"

        if systemctl start "$SERVICE"; then
            echo "旧版本已恢复并成功启动"
        else
            echo "错误：旧版本恢复后也无法启动"
            systemctl --no-pager --full status "$SERVICE" || true
        fi
    else
        echo "错误：无法恢复旧版本"
    fi

    exit 1
fi

sleep 2

# 检查状态
if systemctl is-active --quiet "$SERVICE"; then
    echo
    echo "========================================"
    echo "          CPA 更新成功"
    echo "========================================"
    echo
    echo "版本：$VERSION"
    echo "本体：$CPA_BIN"
    echo

    systemctl --no-pager --full status "$SERVICE"
else
    echo
    echo "CPA 启动失败，正在回滚..."

    systemctl stop "$SERVICE" 2>/dev/null || true

    if cp -f "$BACKUP_BIN" "$CPA_BIN"; then
        chmod 755 "$CPA_BIN"

        if systemctl start "$SERVICE"; then
            echo "旧版本已恢复并成功启动"
        else
            echo "错误：旧版本恢复后无法启动"
            systemctl --no-pager --full status "$SERVICE" || true
        fi
    else
        echo "错误：无法恢复旧版本"
    fi

    exit 1
fi
```
