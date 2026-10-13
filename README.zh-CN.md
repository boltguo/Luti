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

Luti 把 AI 客户端连接到一个已授权项目。AI Host 负责推理和编排；Luti 在本机运行工具，并管理项目边界与权限。

```mermaid
flowchart TB
    remote["ChatGPT"]
    tunnel["OpenAI Secure MCP Tunnel<br/>仅出站连接"]
    luti["这台 Mac 上的 Luti"]
    context["本地记录<br/>Activity"]
    tools["本地能力<br/>Files · Git · Process · Browser"]
    project["一个已授权项目"]

    remote --> tunnel --> luti
    luti --> context --> project
    luti --> tools --> project
```

它可以读写文件、运行构建和测试、查看 Git、操作浏览器、导出产物。这些操作都在你的 Mac 上完成。

## 快速开始

1. **安装 Luti。** 从最新 GitHub Release 下载已签名的 DMG，或从源码构建。
2. **添加文件夹。** 在 **Projects** 中选择一个文件夹，默认完全访问。移除后回到空状态，可重新添加。
3. **配置 OpenAI Tunnel。** 保存 OpenAI Platform 中的 Tunnel ID 和运行 API Key，连接会随 Runtime 自动启动。
4. **在 ChatGPT 中使用。** 在 [ChatGPT Plugins](https://chatgpt.com/plugins) 点击 **+** > **Add custom MCP server**，选择 **Tunnel** 并选中你的 Tunnel ID。

启动 Runtime 前在本地选定文件夹。

**升级到 1.2.0：** 已保存为 1.1 格式的设置和凭据继续保留。1.0.x 旧数据的自动迁移和清理已移除。从 1.0.x 直接升级，或此前迁移未完成的用户，需要重新选择项目文件夹并保存 Tunnel ID 和 API Key。

## 连接方式

| 连接 | 需要提供 | 认证 | 适合场景 |
|---|---|---|---|
| **OpenAI Secure MCP Tunnel** | Tunnel ID + 运行 API Key | ChatGPT 工作区关联 | ChatGPT，无需公开入口 |

Luti 只通过 OpenAI Tunnel 提供 MCP 接入。Luti 下载固定版本并校验哈希的 `tunnel-client`，由它主动连接 OpenAI；本机不对外监听，也没有 OAuth 流程。连接持有一个仅回环的私有监听，只接受每次连接新生成的凭据。连接出错时，Runtime 和运行中的 Job 会保留，Luti 会自动重试。在已连接或重连期间更换 Tunnel ID 或 API Key，需先停止 Runtime，保存新配置后再启动。停止会结束运行中的 Job 和 Luti 管理的浏览器会话。修改系统代理后也需停止并重新启动 Runtime。

## 能力

Luti 对外暴露 **24 个 MCP Tool**，分为 6 个领域。MCP 使用本地选定的文件夹，不提供 `projects`、`memory` 或 `skills` 工具。

| 领域 | Public Tools | 范围 |
|---|---|---|
| Project | `project_info`, `inspect_project`, `runtime_status` | 当前目录、发现、Runtime 状态 |
| Files & Code | `list_directory`, `read_files`, `read_image`, `search_project`, `edit_files`, `path_action`, `code_query` | 搜索、读取、编辑、移动、结构化代码查询 |
| Process & Jobs | `run_process`, `run_shell`, `job_query`, `job_action` | 构建、测试、长任务、日志、PTY 输入、停止 |
| Git | `git_query` | Status、Diff、Log、Show、Blame；只读 |
| Browser | `browser_session`, `browser_observe`, `browser_action`, `browser_transfer`, `browser_inspect`, `browser_dialog`, `browser_evaluate` | 导航、操作、截图、传输、Console、Network、Dialog |
| Artifacts | `export_artifact`, `import_artifact` | 不可变导出与受控导入 |

项目专属能力由项目自己的 manifest、instructions 和 tasks 提供，无需不断增加 Public Tool。

先调用 `project_info`，取得当前目录信息与 `projectToken`。项目写入、命令执行、浏览器修改和 Job 输入需携带该标识；在本地选择其他文件夹或重启 Runtime 后会失效。遇到失配应重新观察并确认目标目录。停止仍归 Runtime 管理的 Job 不受旧标识阻碍。

`code_query` 会启动已安装的语言服务，需要当前 `projectToken`；语言服务可能产生副作用。

Job 结果区分进程完成与识别到的测试结果，并记录有限范围的输入文件观察。`reportPath` 可指定命令生成的 JUnit XML 报告。旧报告、截断输出与无法证明的输入一致性保持 unknown，输入变化标为 stale；这些观察不能证明完整工程正确。

`import_artifact` 可把当前项目 Runtime 中尚未过期的产物保存为项目新文件，最大 32 MiB。不会覆盖、执行或解压文件。网页聊天附件不在当前范围内；只有出现明确 Host 需求且能验证可信文件绑定时再评估 Adapter。

`inspect_project` 返回精简的任务注册表和作用域内的指令来源。选择文件夹后，点击启动即可直接运行。

## 本地记录

Luti 只保留有容量限制的执行活动，存放于 `~/.luti/`，用于排查工具调用问题。本次运行的改动文件和任务验证状态保存在内存中。不会保存会话、记忆或文件恢复数据，也不会向项目仓库写入 Runtime 元数据。

## 安全与隐私

| 边界 | 行为 |
|---|---|
| **项目范围** | 文件与项目操作限制在当前已授权项目中 |
| **权限模式** | Luti 默认对选定文件夹使用完全访问；外部操作仍遵守原有权限边界 |
| **凭据** | Runtime 凭据存入 macOS Keychain；敏感值在持久化前脱敏 |
| **远程访问** | 只有已配置的 OpenAI Tunnel 能访问 Luti；监听仅限回环并绑定凭据 |
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
