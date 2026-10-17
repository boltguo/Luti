<div align="center">

<img src="Luti/Assets.xcassets/LutiIcon.imageset/luti-icon.png" alt="Luti" width="128" height="128">

# Luti

**一个给 AI 用的本地项目运行时。**

让支持 MCP 的 AI 连接到你在 Mac 上选定的文件夹。Luti 提供本地工具和清晰的权限边界。

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE) [![macOS](https://img.shields.io/badge/macOS-14%2B-000000.svg)](#系统要求) [![Swift](https://img.shields.io/badge/Swift-6-F05138.svg)](#从源码构建)

[English](README.md) · 简体中文 · [日本語](README.ja.md)

[官网](https://luti.aouos.com/) · [下载](https://github.com/boltguo/Luti/releases/latest/download/Luti.dmg) · [GitHub](https://github.com/boltguo/Luti) · [支持开发](https://buymeacoffee.com/boltguo)

</div>

<p align="center">
  <img src="Images/luti-overview-zh-CN.png" alt="Luti 中文界面总览">
</p>

## Luti 能做什么

Luti 把 AI 客户端连接到一个已授权项目。AI Host 负责推理和编排；Luti 在本机运行工具，并管理项目边界与权限。它可以读写文件、运行构建和测试、查看 Git、操作浏览器、导出产物，并在多个 AI 客户端之间共享项目记忆。这些操作都在你的 Mac 上完成。

## 快速开始

1. **安装 Luti。** 从最新 GitHub Release 下载已签名的 DMG，或从源码构建。
2. **添加文件夹。** 在 **Projects** 中选择一个文件夹，默认安全模式；可在项目页打开完全访问以跳过确认。移除后回到空状态，可重新添加。
3. **配置连接方式。** 在 **Connections** 中配置 **OpenAI Secure MCP Tunnel** 或 **Cloudflare Tunnel**（两者可单独或同时启用）。
4. **启动并连接。** 启动本地 Runtime 后，在 AI 客户端中添加对应的 MCP 服务即可开始使用。

**升级到 1.2.0：** 已保存为 1.1 格式的设置和凭据继续保留。1.0.x 旧数据的自动迁移和清理已移除。从 1.0.x 直接升级，或此前迁移未完成的用户，需要重新选择项目文件夹并保存 Tunnel ID 和 API Key。

## 连接方式与配置教程

| 连接 | 需要提供 | 认证 | 适合场景 |
|---|---|---|---|
| **OpenAI Secure MCP Tunnel** | Tunnel ID + 运行 API Key | ChatGPT 工作区关联 | ChatGPT，无需公开入口 |
| **Cloudflare Tunnel** | HTTPS 域名 + Tunnel Token | OAuth，在本机弹窗批准 | 通过固定公开地址连接的自定义 MCP 客户端 |

OpenAI 使用独立的回环监听和每次连接新生成的私有凭据，通过 `tunnel-client` 主动出站连接。Cloudflare 为固定 HTTPS 域名单独提供 OAuth 保护的入口。任意一种连接配置完成即可启动，两种连接也可同时运行；传输失败会重连，不重启项目任务。修改配置前先停止 Runtime；停止会结束 Job 和浏览器会话。参见 [Cloudflare 配置与本机授权](docs/cloudflare.md)。

### 1. OpenAI Secure MCP Tunnel（ChatGPT）

1. **创建 Secure MCP Tunnel**：在 [OpenAI Platform Tunnel 设置](https://platform.openai.com/settings/organization/tunnels) 中新建 Tunnel，并关联要使用的 ChatGPT 工作区（需 `Tunnels Read + Manage` 权限）。
2. **创建运行 API Key**：在 [OpenAI API Keys](https://platform.openai.com/api-keys) 创建供 `tunnel-client` 使用的 API Key（需 `Tunnels Read + Use` 权限）。
3. **回到 Luti 完成设置**：填入 Tunnel ID 和 Runtime API Key 并保存，Luti 运行时会自动连接。
4. **在 ChatGPT 中添加**：在 [ChatGPT Plugins](https://chatgpt.com/plugins) 点击 **+** > **Add custom MCP server**，Connection 选择 **Tunnel**，选中你的 Tunnel ID（创建期间保持 Luti 处于连接状态）。

### 2. Cloudflare Tunnel（标准 Web OAuth 客户端，如 ChatGPT / Claude / Grok / Gemini）

1. **创建 Cloudflare Tunnel**：在 [Cloudflare Tunnel 控制台](https://one.dash.cloudflare.com/) 创建或选择远程管理的 Cloudflared 隧道，复制生成的 Tunnel Token。
2. **配置公开域名转发**：为该隧道添加 Public Hostname，绑定你的 HTTPS 域名（如 `https://mcp.example.com`），并将服务地址指向 `http://127.0.0.1:39393`。
3. **回到 Luti 完成设置**：填入 HTTPS 域名和 Tunnel Token 并保存。开启后 Luti 运行时会自动连接。
4. **在 AI 客户端中添加并授权**：将生成的 `https://<你的域名>/mcp` 地址添加为自定义 MCP 服务，认证方式选择 **OAuth**，核对浏览器验证码后在 Luti 弹出的授权窗口中点击 **允许访问**。

### 3. 无回调后端的沙盒客户端（Python 手动 OAuth 接入）

适用于跑在容器/沙盒中、没有公网回调后端的 AI Agent：客户端生成授权链接 → 用户在浏览器打开并在 Luti 弹窗点允许 → 用户把浏览器跳转后的完整回调 URL 粘回给客户端 → 客户端用 `code` 换取 token 并调用 `/mcp`。

1. **服务发现与动态注册（DCR）**
   - 发现端点：`GET /.well-known/oauth-authorization-server` 与 `GET /.well-known/oauth-protected-resource/mcp`
   - 注册客户端：`POST /oauth/register`（JSON Body：`"client_name"`、`"redirect_uris": ["https://..."]`、`"grant_types": ["authorization_code", "refresh_token"]`、`"response_types": ["code"]`、`"scope": "mcp"`、`"token_endpoint_auth_method": "none"`），保存返回的 `client_id`（`luti_` 前缀）。沙盒客户端可填写合法的 `https://` 回调地址占位，靠手动粘回 URL 提取 `code`。
2. **生成 PKCE 授权链接并交由用户批准**
   - 生成 `verifier` 与 `S256` 的 `code_challenge` 及随机 `state` 并持久化保存，拼接 `/oauth/authorize?response_type=code&client_id=...&redirect_uri=...&scope=mcp&state=...&code_challenge=...&code_challenge_method=S256&resource=https://<你的域名>/mcp`。
   - **以代码块/纯文本发送链接**（不要发成可点击卡片，防止聊天平台预抓取导致重复发起授权）。用户在浏览器打开并在 Luti 弹窗批准后，将跳转后的完整回调 URL（含 `?code=...&state=...`）粘回。
3. **换取与刷新 Token（关键避坑）**
   - **一次性轮换与重放保护**：`access_token` 有效期 3600 秒（不透明 Token，有效期内请直接复用，不要每次调用都刷新）。`refresh_token` 为**一次性轮换**，每次刷新返回新 Token 对后旧 `refresh_token` 立即作废，**必须立即以 `0600` 权限落盘新值**；若重复提交已作废的旧 `refresh_token`，服务端会判定凭据泄露并**自动吊销整条授权**（网络超时未拿到响应时切勿盲目用旧 `refresh_token` 重试）。
   - **调用 `/mcp`**：先发送 `initialize` + `notifications/initialized`，再调用 `tools/list` / `tools/call`（修改类工具需先从 `project_info` 获取 `projectToken`）。

```python
import base64, hashlib, json, secrets, urllib.parse, urllib.request

BASE, UA = "https://mcp.example.com", "Mozilla/5.0"
RES, CID, REDIRECT = f"{BASE}/mcp", "<client_id>", "<注册时的 redirect_uri>"

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
    return json.load(urllib.request.urlopen(req, timeout=25))  # 立即持久化新的 access_token 与 refresh_token

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

## 能力

Luti 对外暴露 **24 个 MCP Tool**，分为 7 个领域。MCP 使用本地选定的文件夹，不提供 `projects` 或 `skills` 工具。

| 领域 | Public Tools | 范围 |
|---|---|---|
| Memory | `memory_query`、`memory_action` | 跨 AI 客户端共享的项目记忆：只读的 `index`、`read`；`write`、`delete` 以文件 `sha256` 校验，不会盲目覆盖；`kind=task` 清单把未完成的工作交给下一个会话 |
| Project | `project_info`, `inspect_project`, `runtime_status` | 当前目录、发现、Runtime 状态 |
| Files & Code | `list_directory`, `read_files`, `read_image`, `search_project`, `edit_files`, `path_action`, `code_query` | 搜索、读取、编辑、移动、结构化代码查询 |
| Process & Jobs | `run_process`, `run_shell`, `job_query`, `job_action` | 构建、测试、长任务、日志、PTY 输入、停止 |
| Git | `git_query` | Status、Diff、Log、Show、Blame；只读 |
| Browser | `browser_session`, `browser_observe`, `browser_action`, `browser_transfer`, `browser_evaluate` | 导航、操作、截图、传输、Console、Network、Dialog |
| Artifacts | `export_artifact`, `import_artifact` | 不可变导出与受控导入 |

项目专属能力由项目自己的 manifest、instructions 和 tasks 提供，无需不断增加 Public Tool。

先调用 `project_info`，取得当前目录信息、`projectToken`、带任务进度的记忆文件，以及各 AI 客户端最近的改动。项目写入、记忆修改（`memory_action`）、命令执行、浏览器修改和 Job 输入需携带该标识；在本地选择其他文件夹或重启 Runtime 后会失效。遇到失配应重新观察并确认目标目录。停止仍归 Runtime 管理的 Job 不受旧标识阻碍。

`code_query` 会启动已安装的语言服务，需要当前 `projectToken`；语言服务可能产生副作用。

Job 结果区分进程完成与识别到的测试结果，并记录有限范围的输入文件观察。`reportPath` 可指定命令生成的 JUnit XML 报告。旧报告、截断输出与无法证明的输入一致性保持 unknown，输入变化标为 stale；这些观察不能证明完整工程正确。

`import_artifact` 可把当前项目 Runtime 中尚未过期的产物保存为项目新文件，最大 32 MiB。不会覆盖、执行或解压文件。网页聊天附件不在当前范围内；只有出现明确 Host 需求且能验证可信文件绑定时再评估 Adapter。

`inspect_project` 返回精简的任务注册表和作用域内的指令来源。选择文件夹后，点击启动即可直接运行。

## 本地记录

Luti 在 `~/.luti/` 中按项目保存 `MEMORY.md` 索引与独立 `.md` 决策文档，以及有容量限制的执行活动日志。本次运行的改动文件和任务验证状态保存在内存中。不会保存会话记录或文件恢复数据，也不会向项目仓库写入 Runtime 元数据。

## 安全与隐私

| 边界 | 行为 |
|---|---|
| **项目范围** | 文件与项目操作限制在当前已授权项目中 |
| **权限模式** | `安全模式`（默认）在删除文件、修改 Git、运行 Shell 或内联代码前于本机弹窗确认；`完全访问` 直接执行。两种模式下外部操作均遵守原有权限边界 |
| **凭据** | Runtime 凭据存入 macOS Keychain；敏感值在持久化前脱敏 |
| **远程访问** | 独立的回环监听：OpenAI 使用私有连接凭据，Cloudflare 使用本机批准且绑定域名的 OAuth |
| **Git** | 对外 Git 能力只读 |
| **浏览器自动化** | Luti 只操作自己拥有的 Browser Session；不提供桌面截图或鼠标、键盘控制 |
| **进程执行** | `fullLocal` 使用当前用户权限执行，不是 OS Sandbox |

Luti 没有接收项目数据的云端服务。连接到 Luti 的 AI Host 仍会收到你请求的工具结果，其中可能包含源码、命令输出、截图或其他项目数据。你启用的每个 AI Host 和 Tunnel Provider 都属于信任边界。

## 系统要求

- macOS 14 或更高版本。
- Apple Silicon Mac（arm64）。
- Browser Runtime 需要单独安装 Google Chrome。
- 从源码构建建议使用 Xcode 26+。
- OpenAI 账号、已配置的 Tunnel 和运行 API Key。

应用支持英语、简体中文和日语。

## 从源码构建

```bash
git clone https://github.com/boltguo/Luti.git
cd Luti
open Luti.xcodeproj
```

主要 Scheme 是 `Luti` 和 `LutiProcessHost`。App target 使用 **Apple Development** 自动签名；请在 Signing & Capabilities 中改为自己的 Team，或选择 **Sign to Run Locally**。正式版本启用 Hardened Runtime，并以签名、公证后的 DMG 分发。Sparkle 会检查签名更新，但不会静默安装。

## 开源

Luti 使用 [Apache License 2.0](LICENSE)。第三方依赖与 Bundled Runtime 的许可证声明见 [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES)。

提交变更前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。发现安全漏洞时，请按照 [SECURITY.md](SECURITY.md) 私下报告。

如果 Luti 对你有帮助，可以通过 [Buy Me a Coffee](https://buymeacoffee.com/boltguo) 支持开发。
