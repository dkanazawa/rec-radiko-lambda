#!/bin/bash
#################################################################
# AWS Lambda Handler - Radiko録音＆Google Driveアップロード
# record_and_upload.sh を Lambda 環境用に調整
#################################################################

set -u
EVENT_DATA=$1

# タイムゾーンを日本時間に設定 (Amazon Linux 2023などはデフォルトUTCのため)
export TZ=Asia/Tokyo

# ============================================================================
# 環境変数から設定を読み込む（Secrets Manager から取得された情報も含む）
# ============================================================================

# 放送局設定
STATION_ID="${STATION_ID:-TBS}"
PROGRAM_START="${PROGRAM_START:-0100}"
DURATION_MIN="${DURATION_MIN:-1}"
FILE_NAME_SUFFIX="${FILE_NAME_SUFFIX:-TEST}"
DATE_OFFSET_HOURS="${DATE_OFFSET_HOURS:-5}"

# Google Drive 設定
RCLONE_REMOTE_NAME="${RCLONE_REMOTE_NAME:-MyGoogleDrive}"
GDRIVE_FOLDER_PATH="${GDRIVE_FOLDER_PATH:-}"

# JSONから値を抽出して環境変数を上書き
# ※JSONにキーが存在する場合のみ上書きする
if [ -n "$EVENT_DATA" ] && [ "$EVENT_DATA" != "{}" ]; then
    STATION_ID=$(echo "$EVENT_DATA" | jq -r '.STATION_ID // empty')
    PROGRAM_START=$(echo "$EVENT_DATA" | jq -r '.PROGRAM_START // empty')
    DURATION_MIN=$(echo "$EVENT_DATA" | jq -r '.DURATION_MIN // empty')
    FILE_NAME_SUFFIX=$(echo "$EVENT_DATA" | jq -r '.FILE_NAME_SUFFIX // empty')
    GDRIVE_FOLDER_PATH=$(echo "$EVENT_DATA" | jq -r '.GDRIVE_FOLDER_PATH // empty')
    
    # 抽出した値をログに出力して確認
    echo "Overriding config from event: STATION_ID=$STATION_ID, DURATION=$DURATION_MIN, FILE_NAME_SUFFIX=$FILE_NAME_SUFFIX, GDRIVE_FOLDER_PATH=$GDRIVE_FOLDER_PATH"
fi

# ============================================================================
# 初期化処理
# ============================================================================

# Lambda /tmp ディレクトリをワーキングディレクトリとして使用
WORK_DIR="/tmp"
LOCAL_SAVE_DIR="${WORK_DIR}/radiko_recordings"

# Lambda 環境での実行スクリプトパス
REC_RADIKO_TS_PATH="/var/task/rec_radiko_ts/rec_radiko_ts.sh"

# ログ出力関数
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*" >&2
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

log_debug() {
    # DEBUG ログ（デバッグ時に詳細情報を出力）
    if [ "${DEBUG:-0}" = "1" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $*" >&2
    fi
}

log_info "============================================================"
log_info "Lambda ハンドラー開始"
log_info "============================================================"

# ============================================================================
# PATH を設定（rclone などのバイナリを含める）
# ============================================================================

# PATH に追加
export PATH=$PATH:/usr/bin:/usr/local/bin

# rclone を含むローカルバイナリパスを PATH に追加
RCLONE_BIN_PATH="/var/task/rclone/bin"
if [ -d "$RCLONE_BIN_PATH" ]; then
    export PATH="${RCLONE_BIN_PATH}:${PATH}"
    log_debug "rclone バイナリパスを PATH に追加: $RCLONE_BIN_PATH"
fi

# ============================================================================
# 事前チェック
# ============================================================================

# 必須コマンドの確認
log_info "必須コマンドを確認中..."

# rec_radiko_ts.sh が存在し実行可能か確認
log_info "チェック: rec_radiko_ts.sh = $REC_RADIKO_TS_PATH"
if [ ! -x "$REC_RADIKO_TS_PATH" ]; then
    log_error "ERROR: rec_radiko_ts.sh が見つかりません or 実行可能ではありません"
    log_error "  パス: $REC_RADIKO_TS_PATH"
    log_error "  存在確認: $([ -f "$REC_RADIKO_TS_PATH" ] && echo "存在" || echo "存在しない")"
    log_error "  実行権限: $([ -x "$REC_RADIKO_TS_PATH" ] && echo "あり" || echo "なし")"
    exit 1
fi
log_info "  ✓ OK"

# rclone が PATH 上にあるか確認
log_info "チェック: rclone コマンド"
if ! command -v rclone > /dev/null 2>&1; then
    log_error "ERROR: rclone コマンドが見つかりません"
    log_error "  PATH: $PATH"
    exit 1
fi
RCLONE_PATH=$(command -v rclone)
log_info "  ✓ OK (パス: $RCLONE_PATH)"

# ffmpeg が PATH 上にあるか確認
log_info "チェック: ffmpeg コマンド"
if ! command -v ffmpeg > /dev/null 2>&1; then
    log_error "ERROR: ffmpeg コマンドが見つかりません"
    log_error "  PATH: $PATH"
    exit 1
fi
FFMPEG_PATH=$(command -v ffmpeg)
log_info "  ✓ OK (パス: $FFMPEG_PATH)"

log_info "必須コマンド確認: すべて OK"

# ============================================================================
# 認証情報を取得
# ============================================================================

# 注：Secrets Manager から認証情報を取得するには aws CLI が必要なため
# 環境変数で渡す、または bootstrap スクリプトで取得する必要があります

# 環境変数から rclone 設定を取得（Base64エンコード済み）
if [ -n "${RCLONE_CONFIG_B64:-}" ]; then
    log_info "rclone 設定を環境変数から復元中..."
    mkdir -p ~/.config/rclone
    echo "${RCLONE_CONFIG_B64}" | base64 -d > ~/.config/rclone/rclone.conf
    chmod 600 ~/.config/rclone/rclone.conf
    log_info "rclone 設定を復元しました"
elif [ -f /var/task/config/rclone.conf ]; then
    log_info "configフォルダの rclone 設定ファイルを使用します"
else
    log_warn "rclone 設定が見つかりません。Google Drive へのアップロードは失敗する可能性があります。"
fi

# Radiko Premium認証情報の取得（オプション）
RADIKO_MAIL="${RADIKO_PREMIUM_MAIL:-}"
RADIKO_PASSWORD="${RADIKO_PREMIUM_PASSWORD:-}"

# ============================================================================
# ネットワーク地域確認 (ipinfo.io)
# ============================================================================
# Radiko アクセス拒否の原因が地域制限かどうかを確認するため
log_info "ネットワーク地域情報を取得中..."
log_info "詳細: ipinfo.io にアクセス中..."

if command -v python3 > /dev/null 2>&1; then
    # Python を使用する場合
    ipinfo_response=$(python3 -c "
import requests
import json
try:
    res = requests.get('http://ipinfo.io', timeout=5)
    print(res.text)
except Exception as e:
    print(json.dumps({'error': str(e)}))" 2>&1)
    log_debug "ipinfo.io response: ${ipinfo_response}"
else
    # curl を使用する場合
    ipinfo_response=$(curl -s --max-time 5 'http://ipinfo.io' 2>&1)
    log_debug "ipinfo.io response: ${ipinfo_response}"
fi

# レスポンスを解析してログに出力
if echo "${ipinfo_response}" | grep -q '"ip"'; then
    ip=$(echo "${ipinfo_response}" | grep -o '"ip":"[^"]*' | cut -d'"' -f4)
    country=$(echo "${ipinfo_response}" | grep -o '"country":"[^"]*' | cut -d'"' -f4)
    region=$(echo "${ipinfo_response}" | grep -o '"region":"[^"]*' | cut -d'"' -f4)
    city=$(echo "${ipinfo_response}" | grep -o '"city":"[^"]*' | cut -d'"' -f4)
    
    log_info "ネットワーク地域情報: IP=${ip}, Country=${country}, Region=${region}, City=${city}"
else
    log_warn "ネットワーク地域情報の取得に失敗しました。ipinfo.io が利用不可の可能性があります。"
fi

# ============================================================================
# メイン処理
# ============================================================================

# 1. 保存先ディレクトリが存在しなければ作成
mkdir -p "$LOCAL_SAVE_DIR"
if [ ! -d "$LOCAL_SAVE_DIR" ]; then
    log_error "ローカル保存先ディレクトリを作成できませんでした: $LOCAL_SAVE_DIR"
    exit 1
fi

# 2. ファイル名の生成（深夜番組対応の日付タグ）
DATE_TAG=$(date -d "${DATE_OFFSET_HOURS} hours ago" +%Y年%m月%d日)
DATETIME_START="$(date +%Y%m%d)${PROGRAM_START}"   # 実行日の放送開始時刻に設定
FILE_NAME_BASE="${DATE_TAG} ${FILE_NAME_SUFFIX}"
FILE_NAME_M4A="${FILE_NAME_BASE}.m4a"
FILE_NAME_MP3="${FILE_NAME_BASE}.mp3"

OUTPUT_FILE_M4A="${LOCAL_SAVE_DIR}/${FILE_NAME_M4A}"
OUTPUT_FILE_MP3="${LOCAL_SAVE_DIR}/${FILE_NAME_MP3}"

log_info "処理開始: $(date '+%Y-%m-%d %H:%M:%S')"
log_info "放送局ID: $STATION_ID"
log_info "放送開始: $DATETIME_START"
log_info "録音時間: $DURATION_MIN 分"
log_info "保存ファイル(M4A): $FILE_NAME_M4A"
log_info "保存ファイル(MP3): $FILE_NAME_MP3"

# 3. 録音実行 (m4aで録音)
log_info "録音を開始します..."

# Radiko Premium認証情報がある場合は追加オプションとして渡す
if [ -n "${RADIKO_MAIL:-}" ] && [ -n "${RADIKO_PASSWORD:-}" ]; then
    log_info "Radiko Premium を使用します"
    "$REC_RADIKO_TS_PATH" -s "$STATION_ID" -f "$DATETIME_START" -d "$DURATION_MIN" \
        -m "$RADIKO_MAIL" -p "$RADIKO_PASSWORD" -o "$OUTPUT_FILE_M4A" 2>&1
else
    log_info "Radiko 無償版 を使用します"
    "$REC_RADIKO_TS_PATH" -s "$STATION_ID" -f "$DATETIME_START" -d "$DURATION_MIN" \
        -o "$OUTPUT_FILE_M4A" 2>&1
fi

rec_exit_code=$?

# 4. 録音結果の確認 & MP3変換
if [ $rec_exit_code -eq 0 ] && [ -s "$OUTPUT_FILE_M4A" ]; then
    log_info "録音成功。M4Aサイズ: $(ls -lh "$OUTPUT_FILE_M4A" | awk '{print $5}')"
    
    # ffmpeg による MP3 変換処理
    log_info "MP3への変換を開始します..."
    log_info "実行コマンド: ffmpeg -y -i \"$OUTPUT_FILE_M4A\" -acodec libmp3lame -b:a 48k \"$OUTPUT_FILE_MP3\""
    
    ffmpeg -y -i "$OUTPUT_FILE_M4A" -acodec libmp3lame -b:a 48k "$OUTPUT_FILE_MP3" 2>&1
    
    convert_exit_code=$?
    
    if [ $convert_exit_code -eq 0 ] && [ -s "$OUTPUT_FILE_MP3" ]; then
        log_info "MP3変換成功。MP3サイズ: $(ls -lh "$OUTPUT_FILE_MP3" | awk '{print $5}')"
        
        # 変換成功なら元ファイル(m4a)は削除（容量節約）
        rm -f "$OUTPUT_FILE_M4A"
        
        # 5. Google Driveへのアップロード実行
        log_info "Google Drive へのアップロードを開始します..."
        log_info "アップロード先: ${RCLONE_REMOTE_NAME}:${GDRIVE_FOLDER_PATH}/"
        
        log_info "実行コマンド: rclone copy \"$OUTPUT_FILE_MP3\" \"${RCLONE_REMOTE_NAME}:${GDRIVE_FOLDER_PATH}/\" --config /var/task/config/rclone.conf --log-level INFO"
        rclone copy "$OUTPUT_FILE_MP3" "${RCLONE_REMOTE_NAME}:${GDRIVE_FOLDER_PATH}/" --config /var/task/config/rclone.conf --log-level INFO
        
        upload_exit_code=$?
        
        # 6. アップロード結果の確認
        if [ $upload_exit_code -eq 0 ]; then
            log_info "アップロード成功。"
            
            # 7. ローカルファイルの削除（設定がtrueの場合）
            if [ "${DELETE_LOCAL_FILE_AFTER_UPLOAD:-true}" = true ]; then
                log_info "ローカルファイルを削除します: $OUTPUT_FILE_MP3"
                rm -f "$OUTPUT_FILE_MP3"
            else
                log_info "ローカルファイルを保持します。"
            fi
            
            exit_code=0
        else
            log_error "Google Drive へのアップロードに失敗しました。"
            log_error "ローカルファイルは保持されます: $OUTPUT_FILE_MP3"
            exit_code=1
        fi
    else
        log_error "MP3変換に失敗しました。"
        exit_code=1
    fi
else
    log_error "録音に失敗したか、録音ファイルが空（0バイト）です。"
    log_error "ファイルパス: $OUTPUT_FILE_M4A"
    log_error "終了コード: $rec_exit_code"
    exit_code=1
fi

# ============================================================================
# クリーンアップと終了
# ============================================================================

# /tmp をクリーンアップ（オプション：Lambda 実行後は自動削除されるが、念のため）
# rm -rf "$LOCAL_SAVE_DIR"

log_info "処理終了: $(date '+%Y-%m-%d %H:%M:%S')"
log_info "============================================================"

exit $exit_code
