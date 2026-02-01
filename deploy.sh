#!/bin/bash
set -euo pipefail

# プロジェクトルートディレクトリ（このスクリプトのあるディレクトリ）
PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DIST_DIR="${PROJECT_ROOT}/dist"
ZIP_FILE="${DIST_DIR}/deployment_package.zip"

# 出力ディレクトリ作成
mkdir -p "$DIST_DIR"

# 以前のzipを削除
rm -f "$ZIP_FILE"

echo "Creating deployment package at $ZIP_FILE..."

# 一時作業ディレクトリ
WORK_DIR=$(mktemp -d)

# クリーンアップ関数
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# 1. ソースコードのコピー (src -> root)
echo "Copying source files..."
cp "${PROJECT_ROOT}/src/bootstrap" "$WORK_DIR/"
cp "${PROJECT_ROOT}/src/lambda_handler.sh" "$WORK_DIR/"
chmod 755 "$WORK_DIR/bootstrap" "$WORK_DIR/lambda_handler.sh"

# 2. ライブラリのコピー (lib/rec_radiko_ts -> rec_radiko_ts)
echo "Copying libraries..."
mkdir -p "$WORK_DIR/rec_radiko_ts"
if [ -d "${PROJECT_ROOT}/lib/rec_radiko_ts" ]; then
    cp -r "${PROJECT_ROOT}/lib/rec_radiko_ts/"* "$WORK_DIR/rec_radiko_ts/"
    chmod 755 "$WORK_DIR/rec_radiko_ts/rec_radiko_ts.sh" 2>/dev/null || true
else
    echo "WARNING: lib/rec_radiko_ts not found!"
fi

# 3. バイナリのコピー (bin -> rclone/bin)
# rcloneは bin/rclone として配置されていることを想定
echo "Copying binaries..."
mkdir -p "$WORK_DIR/rclone/bin"
if [ -f "${PROJECT_ROOT}/bin/rclone" ]; then
    cp "${PROJECT_ROOT}/bin/rclone" "$WORK_DIR/rclone/bin/"
    chmod 755 "$WORK_DIR/rclone/bin/rclone"
else
    echo "WARNING: bin/rclone not found! You need to place the rclone binary in bin/ directory."
fi

# 4. 設定ファイルのコピー (config -> config)
echo "Copying configs..."
mkdir -p "$WORK_DIR/config"
if [ -d "${PROJECT_ROOT}/config" ]; then
    # configディレクトリの中身があればコピー
    if [ "$(ls -A "${PROJECT_ROOT}/config")" ]; then
        cp "${PROJECT_ROOT}/config/"* "$WORK_DIR/config/"
    else
        echo "WARNING: config directory is empty. You may need rclone.conf locally."
    fi
else
    mkdir -p "$WORK_DIR/config"
fi

# 5. ZIP作成
echo "Zipping files..."
cd "$WORK_DIR"
zip -r "$ZIP_FILE" . > /dev/null

echo "Done! Package created: $ZIP_FILE"
echo "Contents:"
unzip -l "$ZIP_FILE"
