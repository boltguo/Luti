# Luti 1.4.0

- 恢复**安全模式**，并设为所有项目的默认模式。`rm`、`mv`、`chmod` 等命令、会改变仓库状态的 Git 命令、`run_shell`、内联解释器代码和路径删除，需在本机确认一次后才执行。项目页的“完全访问”开关可关闭确认，运行中切换也立即生效。
- 项目记忆拆分为 `memory_query`（`index`、`read`，只读）和 `memory_action`（`write`、`delete`）。在 AI 客户端中读取记忆不再需要确认。
- 记忆写入不会盲目覆盖：替换或删除文件需提供客户端最后读取到的 `sha256`，多个客户端同时修改时不会互相丢失更新。替换时未提供的名称、描述和类型保持原值。
- 支持 AI 之间接力：多步任务开始前，AI 先写一个带清单的 `kind=task` 记忆文件。`project_info` 会显示每个任务的进度、作者，以及各客户端最近的改动，即使上一个会话中途停止，下一个会话也能接着做。
- `runtime_status` 会报告当前权限模式。
- 工具由 25 个精简为 24 个：`browser_inspect` 的操作并入 `browser_observe`，`browser_dialog` 的 `accept`、`dismiss` 并入 `browser_action`。只读工具不再接收 `projectToken`。
- `git_query`、`path_action`、`edit_files` 和 `code_query` 不再声明属于其他操作的默认值，避免调用失败。
- `run_process` 通过 `-c` 启动 shell 时，执行与 `run_shell` 相同的命令检查。

## 升级须知

**请在每个已连接的 AI 客户端中刷新 Luti 的工具列表**，或删除连接器后重新添加。`memory`、`browser_inspect` 和 `browser_dialog` 已被替换，客户端重新加载工具列表前，调用它们会失败。每当工具列表变化，首页都会显示此提醒，直到你关闭它。

已有项目升级后进入安全模式。如需保持以前的行为，请在项目页打开“完全访问”。

1.1、1.2 或 1.3 中保存的项目、Tunnel 设置、API Key、活动记录、权限和项目记忆均会保留。

需要 macOS 14 或更高版本及 Apple 芯片。浏览器自动化需要 Google Chrome。
