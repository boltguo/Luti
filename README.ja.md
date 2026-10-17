<div align="center">

<img src="Luti/Assets.xcassets/LutiIcon.imageset/luti-icon.png" alt="Luti" width="128" height="128">

# Luti

**AIのためのローカルプロジェクトランタイム。**

MCP対応のAIを、Mac上で選択したフォルダに接続します。Lutiはローカルツールと明確な権限境界を提供します。

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE) [![macOS](https://img.shields.io/badge/macOS-14%2B-000000.svg)](#動作要件) [![Swift](https://img.shields.io/badge/Swift-6-F05138.svg)](#ソースからビルド)

[English](README.md) · [简体中文](README.zh-CN.md) · 日本語

[Website](https://luti.aouos.com/) · [Download](https://github.com/boltguo/Luti/releases/latest/download/Luti.dmg) · [GitHub](https://github.com/boltguo/Luti) · [Support](https://buymeacoffee.com/boltguo)

</div>

<p align="center">
  <img src="Images/luti-overview-ja.png" alt="Luti 日本語インターフェースの概要">
</p>

## Lutiでできること

Lutiは、AIクライアントを承認済みのひとつのプロジェクトにつなぎます。推論とオーケストレーションはAI Hostが担い、ツールのローカル実行、プロジェクト境界と権限はLutiが管理します。ファイルの読み書き、ビルドやテスト、Gitの確認、ブラウザの操作、成果物の書き出し、AI間でのプロジェクトメモリの共有に対応します。これらの操作はすべてMac上で実行されます。

## クイックスタート

1. **Lutiをインストール。** 最新のGitHub Releaseから署名済みのDMGを入手するか、ソースからビルドします。
2. **フォルダを追加。** **Projects**でフォルダを1つ選択します。初期状態はセーフモードで、プロジェクトページでフルアクセスをオンにすると確認を省略できます。削除すると空の状態に戻ります。
3. **接続を設定。** **Connections**で**OpenAI Secure MCP Tunnel**または**Cloudflare Tunnel**を設定します（単独でも同時でも利用可能）。
4. **起動して接続。** ローカルでRuntimeを起動し、AIクライアントにMCPサーバーを追加して利用を開始します。

**1.2.0へのアップグレード：** 1.1形式で保存済みの設定と認証情報は保持されます。1.0.xデータの自動移行と削除は廃止しました。1.0.xから直接更新する場合や、以前の移行が完了していない場合は、プロジェクトフォルダを選び直し、Tunnel IDとAPIキーを再保存してください。

## 接続方式と設定ガイド

| 接続 | 用意するもの | 認証 | 向いている用途 |
|---|---|---|---|
| **OpenAI Secure MCP Tunnel** | Tunnel ID + ランタイムAPIキー | ChatGPTワークスペースの関連付け | 公開Endpointなしで使うChatGPT |
| **Cloudflare Tunnel** | HTTPS ドメイン + Tunnel Token | この Mac のダイアログで承認する OAuth | 固定の公開 URL を使うカスタム MCP クライアント |

OpenAI は接続ごとの新しい Credential と専用 Loopback Listener を使い、`tunnel-client` で送信方向に接続します。Cloudflare は固定 HTTPS ドメイン用に OAuth で保護された独立した入口を提供します。どちらか一方の設定で起動でき、同時接続も可能です。接続障害ではプロジェクトの Job を再起動せず再接続します。設定変更前に Runtime を停止してください。停止すると Job と Browser Session も終了します。[Cloudflare 設定とローカル承認](docs/cloudflare.md)を参照してください。

### 1. OpenAI Secure MCP Tunnel（ChatGPT）

1. **Secure MCP Tunnelを作成**：[OpenAI PlatformのTunnel設定](https://platform.openai.com/settings/organization/tunnels)でTunnelを作成し、使用するChatGPTワークスペースに関連付けます（`Tunnels Read + Manage`権限が必要）。
2. **ランタイムAPIキーを作成**：[OpenAI API Keys](https://platform.openai.com/api-keys)で`tunnel-client`用のAPIキーを作成します（`Tunnels Read + Use`権限が必要）。
3. **Lutiで設定を完了**：Tunnel IDとRuntime API Keyを入力して保存します。Lutiの実行中は自動的に接続します。
4. **ChatGPTに追加**：[ChatGPT Plugins](https://chatgpt.com/plugins)で **+** > **Add custom MCP server** を選び、Connectionで **Tunnel** を選択してTunnel IDを指定します（作成中はLutiを接続したままにしてください）。

### 2. Cloudflare Tunnel（標準Web OAuthクライアント：ChatGPT / Claude / Grok / Gemini）

1. **Cloudflare Tunnelを作成**：[Cloudflare Tunnelダッシュボード](https://one.dash.cloudflare.com/)でリモート管理のCloudflaredトンネルを作成または選択し、Tunnel Tokenをコピーします。
2. **公開ホスト名を転送**：HTTPSドメイン（例：`https://mcp.example.com`）のPublic Hostnameを追加し、サービスURLを `http://127.0.0.1:39393` に設定します。
3. **Lutiで設定を完了**：HTTPSドメインとTunnel Tokenを入力して保存します。有効にすると、Lutiの実行中に自動接続します。
4. **AIクライアントに追加して承認**：生成された `https://<ドメイン>/mcp` をカスタムMCPとして追加し、認証方式で **OAuth** を選び、ブラウザの確認コードを照合してLutiの承認ダイアログで **アクセスを許可** をクリックします。

### 3. コールバックを持たないサンドボックスクライアント（Python手動OAuth接続）

公開コールバックを持たないサンドボックス内のAIエージェントやスクリプト向けの手順です：認可URLを生成 → ユーザーがブラウザで開きLutiのダイアログで許可 → リダイレクト後の完全なURLをクライアントに貼り付け → `code` をトークンに交換して `/mcp` を呼び出します。

1. **ディスカバリと動的クライアント登録（DCR）**
   - ディスカバリ：`GET /.well-known/oauth-authorization-server` と `GET /.well-known/oauth-protected-resource/mcp`
   - 登録：`POST /oauth/register`（JSON：`{"client_name": "...", "redirect_uris": ["https://..."], "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"], "scope": "mcp", "token_endpoint_auth_method": "none"}`）を呼び出し、`client_id`（`luti_` プレフィックス）を保存します。
2. **PKCE認可URLの生成とローカル承認**
   - `verifier`、`S256` の `code_challenge`、`state` を生成・保存し、`/oauth/authorize?response_type=code&client_id=...&redirect_uri=...&scope=mcp&state=...&code_challenge=...&code_challenge_method=S256&resource=https://<ドメイン>/mcp` を組み立てます。
   - **認可URLはプレーンテキスト／コードブロックで送信**してください（リンクカードにするとチャット環境の事前フェッチで重複リクエストが発生します）。承認後、リダイレクト先のURL（`?code=...&state=...`）を貼り付けます。
3. **トークン交換とリフレッシュの注意点**
   - **1回限りのローテーションとリプレイ保護**：`access_token` の有効期限は3600秒です（有効期間中は再利用し、毎回リフレッシュしないでください）。`refresh_token` は**使い捨てローテーション**方式で、更新ごとに古い `refresh_token` は即座に失効するため、**新しいトークン対を直ちに `0600` 権限で保存**してください。使用済み `refresh_token` を再送するとリプレイ保護が作動し、**認可自体が取り消されます**（通信タイムアウト時に古い `refresh_token` で盲目的に再試行しないでください）。
   - **`/mcp` の呼び出し**：`initialize` + `notifications/initialized` の後に `tools/list` / `tools/call` を呼び出します（変更系ツールには `project_info` の `projectToken` が必要です）。

```python
import base64, hashlib, json, secrets, urllib.parse, urllib.request

BASE, UA = "https://mcp.example.com", "Mozilla/5.0"
RES, CID, REDIRECT = f"{BASE}/mcp", "<client_id>", "<登録したredirect_uri>"

def build_auth_url():
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode()
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)
    qs = urllib.parse.urlencode({
        "response_type": "code", "client_id": CID, "redirect_uri": REDIRECT,
        "scope": "mcp", "state": state, "code_challenge": challenge,
        "code_challenge_method": "S256", "resource": RES,
    })
    return f"{BASE}/oauth/authorize?{qs}", verifier, state

def exchange_or_refresh(form):
    data = urllib.parse.urlencode({"client_id": CID, "resource": RES, **form}).encode()
    req = urllib.request.Request(f"{BASE}/oauth/token", data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded", "User-Agent": UA})
    return json.load(urllib.request.urlopen(req, timeout=25))  # 新しい access_token と refresh_token を直ちに保存

def mcp_call(access_token, method, params=None, mid=1):
    body = json.dumps({"jsonrpc": "2.0", "id": mid, "method": method, "params": params or {}}).encode()
    req = urllib.request.Request(RES, data=body, headers={
        "Content-Type": "application/json", "Accept": "application/json, text/event-stream",
        "Authorization": f"Bearer {access_token}", "User-Agent": UA})
    raw = urllib.request.urlopen(req, timeout=30).read().decode()
    for line in raw.splitlines():
        if line.startswith("data:"):
            return json.loads(line[5:])
    return json.loads(raw)
```

## 機能

Lutiは7領域・**25個のPublic MCP Tool**を公開します。MCPはローカルで選択したフォルダを使用し、`projects`、`skills`のToolは公開しません。

| Domain | Public Tools | 範囲 |
|---|---|---|
| Memory | `memory` | プロジェクトの `MEMORY.md` インデックスとトピック別 `.md` 決定ファイル（`index`, `read`, `write`, `delete`） |
| Project | `project_info`, `inspect_project`, `runtime_status` | 現在のWorkspace、Discovery、Runtime状態 |
| Files & Code | `list_directory`, `read_files`, `read_image`, `search_project`, `edit_files`, `path_action`, `code_query` | 検索、読み取り、編集、移動、構造化コード照会 |
| Process & Jobs | `run_process`, `run_shell`, `job_query`, `job_action` | Build、Test、長時間Job、Log、PTY入力、停止 |
| Git | `git_query` | Status、Diff、Log、Show、Blame。読み取り専用 |
| Browser | `browser_session`, `browser_observe`, `browser_action`, `browser_transfer`, `browser_inspect`, `browser_dialog`, `browser_evaluate` | Navigation、Action、Screenshot、Transfer、Console、Network、Dialog |
| Artifacts | `export_artifact`, `import_artifact` | 不変のエクスポート、制御されたインポート |

プロジェクト固有の動作は、そのプロジェクトのmanifest、instructions、tasksで定義します。Public Toolを増やす必要はありません。

最初に `project_info` を呼び出して、現在のWorkspaceと `projectToken` を取得します。Projectへの書き込み、Memoryの更新（`write`/`delete`）、コマンド実行、Browserの変更、Job入力にはこの値が必要です。ローカルで別のフォルダを選択するかRuntimeを再起動すると失効するため、不一致の場合は対象Workspaceを再確認してください。所有するJobの停止は古い値によって妨げられません。

`code_query` はインストール済みの言語サーバーを起動するため、現在の `projectToken` が必要です。言語サーバーは副作用を伴う場合があります。

Jobの結果はプロセス終了と認識したテスト結果を分け、限定した入力ファイルの状態を記録します。`reportPath` でコマンドが生成するJUnit XMLを指定できます。変更のない既存レポート、不完全な出力、証明できない入力の一貫性はunknown、入力の変更はstaleとして扱います。Project全体の正しさを保証するものではありません。

`import_artifact` は現在のProject Runtimeにある有効なArtifactを、最大32 MiBの新規Projectファイルとして保存します。上書き、実行、展開は行いません。チャット添付は現在の対象外とし、具体的なHostが検証可能なファイルバインディングを提供する場合にのみAdapterを再評価します。

`inspect_project`はTask Registryとスコープ内の指示元を簡潔に返します。フォルダ選択後、Startを押すと直接実行を開始します。

## ローカル記録

Lutiはプロジェクトごとのメモリ（`MEMORY.md` インデックスとトピック別 `.md` 決定ファイル）および容量を制限した実行履歴を`~/.luti/`に保存します。現在の実行で変更したファイルとJobの検証状態はメモリに保持します。Sessionやファイル復元データは保存せず、プロジェクト内にもRuntimeメタデータを書き込みません。

## セキュリティとプライバシー

| 境界 | 動作 |
|---|---|
| **Project Scope** | ファイルとProject操作を現在の承認済みProjectに限定 |
| **Permission Mode** | `セーフモード`（既定）はファイル削除、Git変更、シェル・インラインコード実行の前にこのMacで確認します。`フルアクセス`は確認なしで実行します。どちらでも外部操作の権限境界は維持します |
| **Credential** | Runtime CredentialをmacOS Keychainに保存し、機密値を永続化前にRedact |
| **Remote Access** | 独立した Loopback Listener。OpenAI は専用 Credential、Cloudflare はこの Mac で承認したドメインごとの OAuth を使用 |
| **Git** | 公開Git Capabilityは読み取り専用 |
| **ブラウザ自動化** | Lutiが所有するBrowser Sessionのみを操作。デスクトップ撮影やマウス・キーボード操作は提供しません |
| **Process Execution** | `fullLocal`はユーザー権限で実行され、OS Sandboxではない |

Lutiには、プロジェクトデータを受け取るCloud Backendがありません。ただし、接続したAI Hostには要求したTool Resultが送られ、Source Code、Command Output、Screenshotなどが含まれる場合があります。有効にするAI HostとTunnel Providerは、いずれも信頼境界の一部です。

## 動作要件

- macOS 14以降。
- Apple Silicon Mac（arm64）。
- Browser Runtimeには別途Google Chromeが必要。
- ソースビルドにはXcode 26+を推奨。
- OpenAIアカウント、設定済みのTunnelとランタイムAPIキー。

アプリは英語、簡体字中国語、日本語に対応しています。

## ソースからビルド

```bash
git clone https://github.com/boltguo/Luti.git
cd Luti
open Luti.xcodeproj
```

主なSchemeは`Luti`と`LutiProcessHost`です。App targetは**Apple Development**で自動署名します。Signing & Capabilitiesで自分のTeamに変更するか、**Sign to Run Locally**を選択してください。Production ReleaseはHardened Runtimeを有効にし、署名・公証済みDMGとして配布します。Sparkleは署名済みUpdateを確認しますが、自動ではインストールしません。

## オープンソース

Lutiは[Apache License 2.0](LICENSE)で公開しています。Third-party DependencyとBundled RuntimeのLicense Noticeは[THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES)にまとめています。

変更を提案する前に[CONTRIBUTING.md](CONTRIBUTING.md)を確認してください。脆弱性は[SECURITY.md](SECURITY.md)に従って非公開で報告してください。

Lutiが役に立ったら、[Buy Me a Coffee](https://buymeacoffee.com/boltguo)から開発を支援できます。
