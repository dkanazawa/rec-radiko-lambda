# rec-radiko-lambda

AWS Lambda上でRadikoを録音し、Google Driveへアップロードするための機能です。

## プロジェクト構成

```
.
├── src/                # Lambda関数のソースコード
│   ├── bootstrap       # Lambda カスタムランタイムのエントリーポイント
│   └── lambda_handler.sh # メイン処理スクリプト
├── lib/                # 外部ライブラリ・スクリプト
│   └── rec_radiko_ts/  # 録音用スクリプト (git submodule推奨ですが、現在は直接配置)
├── bin/                # 実行バイナリ (gitignore対象)
│   └── rclone          # rcloneバイナリ (手動配置)
├── config/             # 設定ファイル (gitignore対象)
│   ├── rclone.conf     # rclone設定ファイル (手動配置)
│   ├── credentials.json # サービスアカウント認証情報 (必要であれば)
│   ├── rclone.conf.example    # 設定ファイルサンプル
│   └── credentials.json.example # 認証情報サンプル
├── dist/               # デプロイパッケージ出力先
└── deploy.sh           # デプロイパッケージ作成スクリプト
```

## セットアップ手順

### 1. 必要なファイルの配置

Git管理外のファイルを手動で配置してください。

1. **rclone バイナリ**:
   `bin/rclone` に Linux (amd64) 用のバイナリが含まれています。これを使用します。

2. **rclone 設定ファイル**:
   Google Drive 連携用の設定ファイルを `config/` フォルダに配置してください。
   ```bash
   cp config/rclone.conf.example config/rclone.conf
   # config/rclone.conf を編集して正しい設定を記述
   ```

### 2. デプロイパッケージの作成

以下のコマンドを実行すると、`dist/deployment_package.zip` が作成されます。

```bash
./deploy.sh
```

### 3. AWS Lambda へのデプロイ

作成された `dist/deployment_package.zip` を AWS コンソールから Lambda 関数にアップロードしてください。

- **ランタイム**: Custom runtime on Amazon Linux 2 (or AL2023)
- **ハンドラ**: (bootstrapを使用するため設定不要ですが、慣習的に `function.handler` など)

### 4. 留意事項

#### 依存ツールの追加 (Lambda Layer)
この関数を正常に動作させるには、`ffmpeg` と `jq` コマンドが必要です。これらはLambda環境には標準で含まれていないため、**Lambda Layer** を使用して追加してください。

- **ffmpeg**: M4AからMP3への変換に使用します。
  - 参考: [serverlesspub/ffmpeg-aws-lambda-layer](https://github.com/serverlesspub/ffmpeg-aws-lambda-layer)
- **jq**: JSONデータのパースに使用します。

#### Google サービスアカウントについて
本プログラムは、Google Driveへのアップロードにサービスアカウント自身のストレージ容量 (My Drive) を使用することを想定しています。
**2025年4月15日以降に新規作成されたサービスアカウント**については、Googleの仕様変更により自身のストレージを持たない（または制限される）可能性があるため、使用する際はご注意ください。必要に応じて共有ドライブの使用などを検討してください。

## 開発について

- ソースコードは `src/` ディレクトリ内のファイルを編集してください。
- 録音スクリプトのコアロジックは `lib/rec_radiko_ts/` 内にあります。
