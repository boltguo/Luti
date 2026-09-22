/* English comes from index.html. Load before main.js and hero.js. */

(() => {
  const ZH = {
    'meta.title': 'Luti — 云端 AI，连到你的 Mac',
    'meta.desc': "Luti 通过 MCP 将 AI 客户端接到你的 Mac：读写代码、运行测试、操作本机应用，共享已保存的项目记忆。工具结果会返回你使用的 AI 服务。",
    'meta.og': "Luti 通过 MCP 将 AI 客户端接到你的 Mac：读写代码、运行测试、操作本机应用，共享已保存的项目记忆。工具结果会返回你使用的 AI 服务。",

    'nav.context': '项目上下文',
    'nav.caps': '能力',
    'nav.download': '下载',
    'a11y.lang': '界面语言',
    'a11y.theme': '深色模式',
    'a11y.github': 'GitHub 源码',

    'hero.eyebrow': "<b>开源</b> macOS 应用",
    'hero.h1': '云端 AI。<br><em>连到你的 Mac。</em>',
    'hero.lede': "让 AI 读写本机代码、运行测试、操作浏览器和 Mac 应用。支持 MCP 的客户端可以接入同一个项目，继续使用已保存的项目记忆。",
    'hero.ctaChain': "接入指南",
    'hero.ctaDownload': '下载 Mac 版',
    'hero.sr': "流程示意：一个 AI 保存项目决策，另一个读取记忆后修改代码，接着运行测试、检查页面。画面中的对话和结果均为示例。",

    'seed.gptQ': '<b class="mention">@luti</b> 我第一次接这个项目，先给我点背景',
    'seed.gptA': '已连接。acme-dashboard — 24 条记忆、7 个会话、30 个 Tool。',
    'seed.claudeQ': '<b class="mention">@luti</b> 连上了吗？',
    'seed.claudeA': '已连接。Active Project 是 acme-dashboard，vite · pnpm · tsc。',
    'seed.grokQ': '<b class="mention">@luti</b> dev server 还开着吗？',
    'seed.grokA': '已连接。job_7c31 仍在运行——18 通过，0 失败。',
    'seed.codexQ': '<b class="mention">@luti</b> 我现在在哪个项目？',
    'seed.codexA': 'acme-dashboard。和 IDE、网页端是同一个项目、同一份上下文。',

    'stage.linkRemote': '你自己的通道',
    'stage.linkLocal': '本机 localhost',
    'stage.hopLuti': 'Luti · 项目运行时',
    'stage.ctxTitle': '项目记忆',
    'stage.winPreview': '预览 — acme-dashboard',
    'stage.mem1': '只用 pnpm。CI 会拒绝 npm 的 lockfile。',
    'stage.mem2': 'dev 模式下 /api 的代理必须开 changeOrigin，否则 cookie 丢。',
    'stage.mem3': '本地队列不可依赖网络；离线也要能落盘。',
    'stage.miniSub': 'SQLite · 3 workers ready',

    'context.label': '项目上下文',
    'context.title': "换个客户端，接着做。",
    'context.lede': "把决策和约定写进项目记忆，另一个接入的 AI 就能检索并继续工作。记忆需要主动写入，不会自动同步所有聊天记录。",
    'context.memBody': "保存架构选择、项目约定和踩过的坑。每条记忆保留来源与版本，发生更新冲突时拒绝覆盖。",
    'context.sesBody': "回看改过的文件、执行过的任务和测试结果。摘要不包含聊天原文、命令参数和输出正文。",
    'context.sesC1': '改动的路径',
    'context.sesC2': '任务与结果',
    'context.sesC3': '失败与恢复',
    'context.actBody': "查看哪个客户端在什么时候调用了什么工具、结果如何，方便核对改动和排查失败。",
    'context.actC1': '调用者',
    'context.actC2': '工具与效果',
    'context.actC3': '时间线',
    'context.f1': '一次工具调用',
    'context.f2': '模型判断什么值得长期留下',

    'caps.label': '本机能力',
    'caps.title': "从修改代码，到检查运行结果。",
    'caps.lede': "把任务交给 AI，Luti 在你的 Mac 上执行本机操作。读取的代码、命令输出和截图，可以作为工具结果返回对话。",

    'chain.label': '工作方式',
    'chain.title': '模型在上面想，Luti 在下面做。',
    'chain.lede': '上层 AI 负责理解、规划和编排。Luti 负责项目边界、长期上下文、本机能力、审批和留痕。中间只有 MCP。',
    'chain.traceAlt': '按顺序的七次工具调用：memory recall 命中 3 条；inspect_project 识别出 vite、pnpm、tsc；read_files 读了 src/queue.ts 的 142 行；edit_files 落盘 +12 −3；run_process 提交 pnpm test 为 job_7c31；job_query 返回 18 通过 0 失败；memory remember 把这条决定写回去，编号 mem_9f3c1。',
    'chain.figAlt': '三层结构：任意兼容 MCP 的 AI Host 在上，Luti 项目运行时在中间，macOS 在下。',
    'chain.b1': '任意兼容 MCP 的 AI Host',
    'chain.b1d': '推理 · 规划 · 编排',
    'chain.a1': '你自己的通道，或 localhost',
    'chain.b2d': "当前项目 · 按已配置的权限执行",
    'chain.r1': '项目上下文',
    'chain.r2': '本机能力',
    'chain.b3d': '~/.luti — 每个项目一个命名空间',
    'chain.traceLabel': "工具调用示例",

    'chain.t1': '持久上下文归 <em>Luti</em>，<br>上下文的智能归模型。',
    'chain.t2': '项目能力归 <em>Luti</em>，<br>推理和编排留在 Host。',

    'sec.label': '安全',
    'sec.title': "由你决定 AI 能访问什么。",
    'sec.lede': "选择开放哪些项目，配置工具权限，并在本机查看调用记录和结果。",
    'sec.r1': '一次只激活一个项目',
    'sec.r1b': "项目由你在 Mac 上添加，客户端可在已批准的项目之间切换。切换时，旧项目的工作区、任务、浏览器和产物会一并撤销。",
    'sec.r3': "不同接入方式，分别认证",
    'sec.r3b': "公开 HTTPS 接入使用 OAuth，需要在 Mac 上批准。OpenAI Tunnel 使用工作区授权凭据；Local MCP 使用本机 bearer 凭据。工具权限另行控制。",
    'sec.r5': '每一次调用都留痕',
    'sec.r5b': "操作记录包含调用方、工具、时间和结果。调用方身份来自已认证的连接。",
    'sec.r8': "结构化文件修改可恢复",
    'sec.r8b': "edit_files 和 path_action 修改文件前会保存检查点，停止运行时后可在本机恢复。Shell 命令和外部应用造成的修改不在此范围内。",
    'sec.r6': '项目上下文不进你的仓库',
    'sec.r6b': "项目记忆、会话和操作记录存放在仓库之外的 <code>~/.luti/</code>。连接凭据存入 macOS 钥匙串。",
    'sec.r7': '关掉就是真的关掉',
    'sec.r7b': "停止运行时，会关闭连接，并停止由它管理的任务和浏览器会话。",
    'sec.noteTitle': '边界到哪里为止',
    'sec.n1': "<b>本机执行不等于系统沙箱。</b>获准运行的进程可能使用你的 macOS 用户权限。",
    'sec.n2': "<b>工具结果会发送给你使用的 AI 服务。</b>其中可能包含代码、命令输出和截图。Luti 没有接收项目数据的自营云服务。",
    'sec.n3': '<b>只对经过 Luti 的操作负责。</b>Host 自己在别处执行的动作在这条边界之外。',

    'tools.t1': '上下文',
    'tools.t1b': '检索项目已经知道的事，写回值得留下的结论，回顾会话，逻辑遗忘一条而不丢历史。',
    'tools.t2': '项目',
    'tools.t2b': '列出并切换已批准的项目，从项目本身识别技术栈，看运行时此刻在做什么。',
    'tools.t3': '文件与代码',
    'tools.t3b': "搜索文件和代码符号，修改代码，查看 Git 差异。通过结构化文件工具修改时，会先保存检查点。",
    'tools.t4': '进程与任务',
    'tools.t4b': "把构建、测试和开发服务器作为后台任务运行。在对话里查看日志、回应交互提示，或停止任务。",
    'tools.t5': 'Git',
    'tools.t5b': '状态、差异、日志、blame——只读。它告诉你改了什么，不替你提交。',
    'tools.t6': '浏览器',
    'tools.t6b': "打开本机预览，点击页面，生成截图或 PDF，也能检查控制台错误和网络请求。",
    'tools.t7': 'Computer Use',
    'tools.t7b': "在你授予的 macOS 权限下，查看窗口、操作原生应用和系统对话框。",
    'tools.t8': '技能与产物',
    'tools.t8b': '项目里写下的 skills 会成为这个项目的专属能力。截图、PDF、构建产物按 MCP 的资源形式回到对话里。',
    'tools.all': '全部 30 个 Tool',

    'start.label': '快速开始',
    'start.title': "接入你的 AI，试一个任务。",
    'start.lede': "ChatGPT 可通过 OpenAI Secure MCP Tunnel 接入，账号和工作区需具备开发者模式及 Tunnel 权限。其他接入方式见下方。",
    'start.s1': "安装 Luti，选择项目",
    'start.s1b': "下载 Luti，在 Projects 中添加项目文件夹，启动运行时。",
    'start.s2': "连接 OpenAI Tunnel",
    'start.s2b': "在 OpenAI Platform 创建 Tunnel，关联 ChatGPT 工作区。把 Tunnel ID 和具备 Tunnel Read + Use 权限的运行时 API Key 填入 Luti → Connections → OpenAI，再启用连接。",
    'start.s3': "在 ChatGPT 添加 Luti",
    'start.s3b': "在 ChatGPT 设置中启用开发者模式，进入应用页面创建应用。连接方式选择 Tunnel，选中对应 Tunnel ID。Luti 的 OpenAI 连接不走公开 HTTPS 的 OAuth 流程。",
    'start.s4': "用一个小任务确认接通",
    'start.s4b': "在新对话中选择 Luti，试着说：“列出我当前项目的顶层文件。”确认返回的内容与 Mac 上的项目一致。",
    'start.foot': "浏览器自动化目前需要 Apple Silicon 芯片，并安装 Google Chrome。",

    'footer.tagline': '项目的上下文和能力，属于项目本身。',
    'footer.product': '产品',
    'footer.source': 'GitHub 源码',
    'footer.hosts': 'AI 客户端',
    'footer.entrances': "连接方式",
    'footer.support': '请我喝杯咖啡',
    'footer.legal': '© 2026 Luti · 为 macOS 打造 · 你的项目，属于你',

    'demo.idle': '等待调用',
    'demo.pause': '暂停演示',
    'demo.resume': '继续演示',
    'demo.askRemember': '本地队列改用 SQLite，把这个决定记进项目',
    'demo.callRemember': 'action=remember',
    'demo.kindDecision': 'decision',
    'demo.memNew': '本地队列改用 SQLite；JSON ledger 保留一个版本只读。',
    'demo.replyRemember': '已写进项目记忆。之后接进这个项目的 AI 都会读到。',
    'demo.askApply': '动数据层之前先查下项目里的规矩，然后照着改 queue.ts',
    'demo.callRecall': 'action=recall',
    'demo.callEdit': 'action=edit',
    'demo.replyApply': '项目里已经有答案了，我照着写进了 queue.ts：',
    'demo.askPreview': '把预览打开，我看看跑起来的样子',
    'demo.callOpen': 'action=open',
    'demo.replyPreview': '预览已打开：<b>localhost:5173</b>，dev server 就绪，队列已渲染。',
    'demo.askShot': '帮我截个图，我不在那台机器上',
    'demo.callShot': 'action=screenshot',
    'demo.replyShot': '那台 Mac 现在就是这样：',
    'demo.memSrcNew': 'claude · now',
    'demo.count': '24 条记忆 · 7 个会话',
    'demo.countNew': '25 条记忆 · 7 个会话',
    'hero.requirements': "macOS 14+ · 支持 Apple Silicon 和 Intel",
    'hero.demoNote': "流程示意 · 对话与结果均为示例",
    'caps.task3': "读代码，改文件",
    'caps.task4': "构建、测试、跑服务",
    'caps.task6': "打开页面，检查效果",
    'caps.task7': "操作 Mac 应用",
    'context.memTitle': "项目记忆",
    'context.sesTitle': "会话记录",
    'context.actTitle': "操作记录",
    'start.https': "其他远程客户端 · HTTPS + OAuth",
    'start.httpsBody': "在 Luti 的 Connections 中配置 Cloudflare 或 ngrok。把以 <code>/mcp</code> 结尾的完整 HTTPS 地址添加到支持远程 MCP 和 OAuth 的客户端，完成 OAuth，并在 Mac 上批准访问。是否支持取决于客户端和账号。",
    'start.local': "本机客户端 · Local MCP",
    'start.localBody': "启动运行时后，在 Connections 的 Local MCP 中复制配置，填入客户端的 MCP 设置。配置包含本机地址与 bearer 凭据，无需远程 Tunnel。",
    'start.guide': "OpenAI Tunnel 配置文档 ↗",
  };

  const JA = {
    'meta.title': 'Luti — クラウドのAIが、あなたのMacに。',
    'meta.desc': "LutiはMCPでAIクライアントとMacを接続。コード編集、テスト、アプリ操作、保存したプロジェクトメモリの共有に対応。ツールの結果は利用するAIサービスに返されます。",
    'meta.og': "LutiはMCPでAIクライアントとMacを接続。コード編集、テスト、アプリ操作、保存したプロジェクトメモリの共有に対応。ツールの結果は利用するAIサービスに返されます。",

    'nav.context': 'プロジェクトコンテキスト',
    'nav.caps': 'ローカル機能',
    'nav.download': 'ダウンロード',
    'a11y.lang': '表示言語',
    'a11y.theme': 'ダークモード',
    'a11y.github': 'GitHubのソース',

    'hero.eyebrow': "<b>オープンソース</b> macOSアプリ",
    'hero.h1': 'クラウドのAIが、<br><em>あなたのMacに。</em>',
    'hero.lede': "AIからローカルのコードを読み書きし、テストを実行。ブラウザやMacのアプリも操作できます。MCP対応クライアントで、同じプロジェクトと保存したメモリを共有できます。",
    'hero.ctaChain': "接続ガイド",
    'hero.ctaDownload': 'Mac版をダウンロード',
    'hero.sr': "動作イメージ：AIがプロジェクトの決定事項を保存し、別のAIがそれを読み出してコードを編集。テストと画面の確認まで行います。表示される会話や結果は例です。",

    'seed.gptQ': '<b class="mention">@luti</b> このプロジェクトは初めてです。まず背景を教えてください',
    'seed.gptA': '接続済み。acme-dashboard — メモリ24件、セッション7件、ツール30個。',
    'seed.claudeQ': '<b class="mention">@luti</b> つながっていますか？',
    'seed.claudeA': '接続済み。使用中のプロジェクトはacme-dashboard。vite · pnpm · tsc。',
    'seed.grokQ': '<b class="mention">@luti</b> devサーバはまだ動いていますか？',
    'seed.grokA': '接続済み。job_7c31は実行中。18件成功、0件失敗。',
    'seed.codexQ': '<b class="mention">@luti</b> 今はどのプロジェクトですか？',
    'seed.codexA': 'acme-dashboardです。IDEでもWebでも、同じプロジェクト、同じコンテキスト。',

    'stage.linkRemote': '自分のトンネル',
    'stage.linkLocal': 'ローカルのlocalhost',
    'stage.hopLuti': 'Luti · プロジェクトランタイム',
    'stage.ctxTitle': 'プロジェクトメモリ',
    'stage.winPreview': 'プレビュー — acme-dashboard',
    'stage.mem1': 'pnpmのみ。CIはnpmのlockfileを拒否します。',
    'stage.mem2': 'devの/apiプロキシにはchangeOriginが必要。ないとcookieが落ちます。',
    'stage.mem3': 'ローカルキューはネットワークに依存しない。オフラインでも書き込めること。',
    'stage.miniSub': 'SQLite · 3 workers ready',

    'context.label': 'プロジェクトコンテキスト',
    'context.title': "クライアントを替えても、作業の続きを。",
    'context.lede': "決定事項や規約をプロジェクトメモリに保存すると、別のAIからも参照できます。メモリは明示的に書き込むもので、会話全体の自動同期ではありません。",
    'context.memBody': "設計方針、規約、過去の作業で得た知見を保存。出典と版を保持し、競合する更新は拒否します。",
    'context.sesBody': "変更したファイル、実行したジョブ、テスト結果を振り返れます。要約には会話原文、コマンド引数、出力本文を含めません。",
    'context.sesC1': '変更したパス',
    'context.sesC2': 'ジョブと結果',
    'context.sesC3': '失敗とリカバリ',
    'context.actBody': "どのクライアントが、いつ、何のツールを使い、どう終わったかを確認。変更の確認やエラーの調査に使えます。",
    'context.actC1': '呼び出し元',
    'context.actC2': 'ツールと影響',
    'context.actC3': 'タイムライン',
    'context.f1': 'ツールの呼び出し',
    'context.f2': '何を残すかは、モデルが決める',

    'caps.label': 'ローカル機能',
    'caps.title': "コードの編集から、動作の確認まで。",
    'caps.lede': "AIに依頼すると、LutiがMac上で必要な操作を実行します。読み取ったコード、コマンド出力、スクリーンショットはツールの結果として会話に返されます。",

    'chain.label': '仕組み',
    'chain.title': '考えるのはモデル。動かすのはLuti。',
    'chain.lede':
      '理解も計画もオーケストレーションも、上のAIのもの。プロジェクトの境界、永続コンテキスト、ローカル機能、承認と記録は、Lutiのもの。あいだにあるのはMCPだけです。',
    'chain.traceAlt':
      '順に7回のツール呼び出し。memory recallが3件に一致し、inspect_projectがvite、pnpm、tscを検出。read_filesがsrc/queue.tsを142行読み、edit_filesが+12 −3を適用。run_processがpnpm testをjob_7c31として投入し、job_queryが18件成功・0件失敗を返し、memory rememberが決定をmem_9f3c1として書き戻します。',
    'chain.figAlt': '3つの層。上にMCP対応のAIホスト、中央にLutiプロジェクトランタイム、下にmacOS。',
    'chain.b1': 'MCP対応のAIホスト',
    'chain.b1d': '推論 · 計画 · オーケストレーション',
    'chain.a1': '自分のトンネル、またはlocalhost',
    'chain.b2d': "選択中のプロジェクト · 設定した権限で実行",
    'chain.r1': 'プロジェクトコンテキスト',
    'chain.r2': 'ローカル機能',
    'chain.b3d': '~/.luti — プロジェクトごとに一つの名前空間',
    'chain.traceLabel': "ツール呼び出しの例",

    'chain.t1': '永続コンテキストは<em>Luti</em>に。<br>コンテキストの知性はモデルに。',
    'chain.t2': 'プロジェクトの機能は<em>Luti</em>に。<br>推論とオーケストレーションはホストに。',

    'sec.label': 'セキュリティ',
    'sec.title': "AIに許可するアクセスを、自分で選ぶ。",
    'sec.lede': "公開するプロジェクトとツールの権限を設定。呼び出しと結果はMac上の操作ログで確認できます。",
    'sec.r1': '使用中のプロジェクトは、一度にひとつ',
    'sec.r1b': "プロジェクトはMacで追加します。クライアントは承認済みのプロジェクト間で切り替え可能。切り替えると、前のワークスペース、ジョブ、ブラウザ、成果物へのアクセスを解除します。",
    'sec.r3': "接続方式に応じた認証",
    'sec.r3b': "公開HTTPS接続はOAuthを使い、Macでの承認が必要です。OpenAI Tunnelはワークスペース認証、Local MCPはローカルのbearer認証を使用。ツール権限は別に適用されます。",
    'sec.r5': 'すべての呼び出しが、記録に残ります',
    'sec.r5b': "操作ログには呼び出し元、ツール、時刻、結果を記録。呼び出し元の識別には認証済み接続を使います。",
    'sec.r8': "構造化ファイル編集のチェックポイント",
    'sec.r8b': "edit_filesとpath_actionは変更前にチェックポイントを保存。ランタイムを停止してMac上で復元できます。シェルや外部アプリによる変更は対象外です。",
    'sec.r6': 'プロジェクトのコンテキストは、リポジトリに入りません',
    'sec.r6b': "メモリ、セッション、操作ログはリポジトリ外の <code>~/.luti/</code> に保存。接続認証情報はmacOSキーチェーンに保管します。",
    'sec.r7': 'オフは、オフ',
    'sec.r7b': "ランタイムを停止すると、接続を閉じ、管理中のジョブとブラウザセッションを停止します。",
    'sec.noteTitle': '境界が終わるところ',
    'sec.n1': "<b>ローカル実行はOSのサンドボックスとは異なります。</b>承認したプロセスはmacOSユーザーの権限で実行される場合があります。",
    'sec.n2': "<b>ツールの結果は利用するAIサービスに送られます。</b>コード、コマンド出力、スクリーンショットを含む場合があります。Luti独自のクラウドサービスにプロジェクトデータを送ることはありません。",
    'sec.n3': '<b>Lutiを通ったものが、Lutiの責任です。</b>ホストが自分で別の場所で実行したことは、その外側です。',

    'tools.t1': 'コンテキスト',
    'tools.t1b': 'プロジェクトがすでに知っていることを引き出し、残す価値のある結論を書き戻し、セッションを振り返り、履歴を残したまま無効にする。',
    'tools.t2': 'プロジェクト',
    'tools.t2b': '承認済みプロジェクトの一覧と切り替え、プロジェクト自身からのスタック検出、いまのランタイムの状態。',
    'tools.t3': 'ファイルとコード',
    'tools.t3b': "ファイルやシンボルを検索し、コードを編集してGitの差分を確認。構造化ファイル編集では、変更前にチェックポイントを保存します。",
    'tools.t4': 'プロセスとジョブ',
    'tools.t4b': "ビルド、テスト、開発サーバーをバックグラウンドで実行。会話からログの確認、入力への応答、停止ができます。",
    'tools.t5': 'Git',
    'tools.t5b': '状態、差分、ログ、blame。読み取り専用です。何が変わったかは見せますが、代わりにコミットはしません。',
    'tools.t6': 'ブラウザ',
    'tools.t6b': "ローカルのプレビューを開き、ページを操作してスクリーンショットやPDFを取得。コンソールエラーと通信も確認できます。",
    'tools.t7': 'Computer Use',
    'tools.t7b': "許可したmacOS権限の範囲で、ウインドウを確認し、アプリやシステムダイアログを操作します。",
    'tools.t8': 'スキルと成果物',
    'tools.t8b': 'プロジェクトに書かれたskillsが、そのプロジェクトの機能になります。スクリーンショットもPDFもビルド成果物も、MCPのリソースとして会話に戻ります。',
    'tools.all': '30のツールをすべて見る',

    'start.label': 'はじめる',
    'start.title': "AIを接続して、最初のタスクへ。",
    'start.lede': "ChatGPTにはOpenAI Secure MCP Tunnelを利用できます。アカウントとワークスペースで開発者モードとTunnelを利用できる必要があります。その他の接続方法は下にあります。",
    'start.s1': "Lutiをインストールし、プロジェクトを選ぶ",
    'start.s1b': "Lutiをダウンロードし、Projectsでフォルダを追加してランタイムを起動します。",
    'start.s2': "OpenAI Tunnelを接続する",
    'start.s2b': "OpenAI PlatformでTunnelを作成し、ChatGPTワークスペースを関連付けます。Luti → Connections → OpenAIにTunnel IDとTunnelのRead + Use権限を持つ実行用APIキーを入力し、接続を有効にします。",
    'start.s3': "ChatGPTにLutiを追加する",
    'start.s3b': "ChatGPTの設定で開発者モードを有効にし、アプリ画面からアプリを作成。接続方式にTunnelを選び、該当のTunnel IDを指定します。LutiのOpenAI接続では公開HTTPS用のOAuthを使いません。",
    'start.s4': "小さなタスクで接続を確認する",
    'start.s4b': "新しい会話でLutiを選び、「選択中のプロジェクトの最上位にあるファイルを一覧にして」と依頼。Macのフォルダと結果が一致するか確認します。",
    'start.foot': "ブラウザ自動操作には現在、Apple SiliconとGoogle Chromeのインストールが必要です。",

    'footer.tagline': 'プロジェクトのコンテキストと機能は、プロジェクトのもの。',
    'footer.product': '製品',
    'footer.source': 'GitHubのソース',
    'footer.hosts': 'ホスト',
    'footer.entrances': "接続方法",
    'footer.support': 'コーヒーを一杯おごる',
    'footer.legal': '© 2026 Luti · macOSのために · あなたのプロジェクトは、あなたのもの',

    'demo.idle': '呼び出し待ち',
    'demo.pause': 'デモを一時停止',
    'demo.resume': 'デモを再開',
    'demo.askRemember': 'ローカルキューをSQLiteに移します。その決定をプロジェクトに記録してください',
    'demo.callRemember': 'action=remember',
    'demo.kindDecision': 'decision',
    'demo.memNew': 'ローカルキューはSQLiteへ。JSON ledgerは1リリースのあいだ読み取り専用。',
    'demo.replyRemember': 'プロジェクトメモリに書き込みました。このプロジェクトにつなぐAIは、すべて読みます。',
    'demo.askApply': 'データ層に触れる前にプロジェクトを確認して、queue.tsに反映してください',
    'demo.callRecall': 'action=recall',
    'demo.callEdit': 'action=edit',
    'demo.replyApply': 'プロジェクトに答えがありました。そのままqueue.tsに書いています。',
    'demo.askPreview': 'プレビューを開いて、動いているところを見せてください',
    'demo.callOpen': 'action=open',
    'demo.replyPreview': 'プレビューを開きました。<b>localhost:5173</b>、devサーバ準備完了、キューも描画されています。',
    'demo.askShot': 'スクリーンショットを撮ってください。そのマシンの前にいないので',
    'demo.callShot': 'action=screenshot',
    'demo.replyShot': 'そのMacが今映しているものです。',
    'demo.memSrcNew': 'claude · now',
    'demo.count': 'メモリ24件 · セッション7件',
    'demo.countNew': 'メモリ25件 · セッション7件',
    'hero.requirements': "macOS 14以降 · Apple Silicon / Intel対応",
    'hero.demoNote': "動作イメージ · 会話と結果は例です",
    'caps.task3': "コードを読み、編集する",
    'caps.task4': "ビルドとテストを実行する",
    'caps.task6': "実際のページを確認する",
    'caps.task7': "Macのアプリを操作する",
    'context.memTitle': "プロジェクトメモリ",
    'context.sesTitle': "セッション履歴",
    'context.actTitle': "操作ログ",
    'start.https': "その他のリモートクライアント · HTTPS + OAuth",
    'start.httpsBody': "LutiのConnectionsでCloudflareまたはngrokを設定。<code>/mcp</code> で終わるHTTPS接続先を、リモートMCPとOAuthに対応するクライアントに追加し、OAuthを完了してMacで承認します。利用可否はクライアントとアカウントによります。",
    'start.local': "このMac上のクライアント · Local MCP",
    'start.localBody': "ランタイムを起動し、ConnectionsのLocal MCPから設定をコピーして、クライアントのMCP設定に登録します。ローカル接続先とbearer認証情報が含まれ、リモートTunnelは不要です。",
    'start.guide': "OpenAI Tunnelの設定ドキュメント ↗",
  };

  /* Metadata and demo strings without corresponding HTML nodes. */
  const EN = {
    'meta.title': 'Luti — Cloud AI, on your Mac.',
    'meta.desc': "Luti connects AI clients to your Mac through MCP: read and edit code, run tests, use local apps, and share saved project memory. Tool results return to your AI provider.",
    'meta.og': "Luti connects AI clients to your Mac through MCP: read and edit code, run tests, use local apps, and share saved project memory. Tool results return to your AI provider.",
    'stage.linkLocal': 'localhost',
    'demo.resume': 'Resume demo',
    'demo.askRemember': 'local queue moves to SQLite — put that decision in the project',
    'demo.callRemember': 'action=remember',
    'demo.kindDecision': 'decision',
    'demo.memNew': 'Local queue moves to SQLite. The JSON ledger stays read-only for one release.',
    'demo.replyRemember':
      'Written to project memory. Every AI that connects to this project reads it.',
    'demo.askApply': 'check the project before I touch the data layer, then apply it to queue.ts',
    'demo.callRecall': 'action=recall',
    'demo.callEdit': 'action=edit',
    'demo.replyApply': 'The project already had the answer, so I wrote it into queue.ts:',
    'demo.askPreview': 'open the preview so I can see it running',
    'demo.callOpen': 'action=open',
    'demo.replyPreview':
      'Preview is up at <b>localhost:5173</b> — dev server ready, the queue renders.',
    'demo.askShot': 'screenshot it for me — I am not on that machine',
    'demo.callShot': 'action=screenshot',
    'demo.replyShot': 'Here is what that Mac is showing right now:',
    'demo.memSrcNew': 'claude · now',
    'demo.countNew': '25 memories · 7 sessions',
  };

  /* New languages also need a menu item and hreflang link in index.html. */
  const LANGS = {
    en: { html: 'en', og: 'en_US', short: 'EN', dict: EN },
    zh: { html: 'zh-Hans', og: 'zh_CN', short: '中', dict: ZH },
    ja: { html: 'ja', og: 'ja_JP', short: '日', dict: JA },
  };

  /* Capture the English markup before translation. */

  const desc = document.querySelector('meta[name="description"]');
  const nodes = [];
  const attrs = [];

  document.querySelectorAll('[data-i18n], [data-i18n-html]').forEach(el => {
    const html = el.hasAttribute('data-i18n-html');
    const key = el.dataset.i18nHtml || el.dataset.i18n;
    const en = html ? el.innerHTML : el.textContent;
    nodes.push({ el, key, html, en });
    if (!(key in EN)) EN[key] = en;
  });

  document.querySelectorAll('[data-i18n-attr]').forEach(el => {
    /* Comma-separated attribute:key pairs. */
    el.dataset.i18nAttr.split(',').forEach(pair => {
      const [name, key] = pair.split(':').map(t => t.trim());
      if (!name || !key) return;
      const en = el.getAttribute(name) ?? '';
      attrs.push({ el, name, key, en });
      if (!(key in EN)) EN[key] = en;
    });
  });

  const KEY = 'luti-lang';
  const listeners = [];
  let lang = 'en';

  const lookup = (l, key, fallback) => LANGS[l].dict[key] ?? fallback;
  const t = key => lookup(lang, key, EN[key] ?? key);

  /* Keep the URL and hreflang metadata aligned with the selected language. */
  const seo = {
    ogTitle: document.querySelector('meta[property="og:title"]'),
    ogDesc: document.querySelector('meta[property="og:description"]'),
    ogLocale: document.querySelector('meta[property="og:locale"]'),
    ogLocaleAlts: [...document.querySelectorAll('meta[property="og:locale:alternate"]')],
    twTitle: document.querySelector('meta[name="twitter:title"]'),
    twDesc: document.querySelector('meta[name="twitter:description"]'),
  };

  function apply(next) {
    lang = Object.hasOwn(LANGS, next) ? next : 'en';
    const meta = LANGS[lang];
    document.documentElement.lang = meta.html;

    for (const n of nodes) {
      const v = lookup(lang, n.key, n.en);
      if (n.html) n.el.innerHTML = v;
      else n.el.textContent = v;
    }
    for (const a of attrs) a.el.setAttribute(a.name, lookup(lang, a.key, a.en));

    document.title = t('meta.title');
    if (desc) desc.content = t('meta.desc');

    const og = t('meta.og');
    if (seo.ogTitle) seo.ogTitle.content = t('meta.title');
    if (seo.ogDesc) seo.ogDesc.content = og;
    if (seo.twTitle) seo.twTitle.content = t('meta.title');
    if (seo.twDesc) seo.twDesc.content = og;
    if (seo.ogLocale) seo.ogLocale.content = meta.og;

    const others = Object.keys(LANGS).filter(l => l !== lang);
    seo.ogLocaleAlts.forEach((el, i) => {
      if (others[i]) el.content = LANGS[others[i]].og;
    });

    document.querySelectorAll('[data-lang]').forEach(b => {
      b.setAttribute('aria-checked', String(b.dataset.lang === lang));
    });
    document.querySelectorAll('[data-lang-value]').forEach(el => {
      el.textContent = meta.short;
      el.lang = meta.html;
    });
  }

  function set(next, persist = true) {
    if (next === lang) return;
    apply(next);
    if (persist) {
      try { localStorage.setItem(KEY, lang); } catch {}
      try {
        const url = new URL(location.href);
        url.searchParams.set('lang', lang);
        history.replaceState(null, '', url);
      } catch {}
    }
    listeners.forEach(fn => fn(lang));
    dispatchEvent(new CustomEvent('luti:lang', { detail: lang }));
  }

  /* Language priority: URL, saved choice, English. */
  let stored = null;
  try { stored = new URL(location.href).searchParams.get('lang'); } catch {}
  if (!Object.hasOwn(LANGS, stored)) {
    stored = null;
    try { stored = localStorage.getItem(KEY); } catch {}
  }
  apply(stored);

  document.querySelectorAll('[data-lang]').forEach(b => {
    b.addEventListener('click', () => set(b.dataset.lang));
  });

  window.lutiI18n = {
    get lang() { return lang; },
    t,
    set,

    on(fn) { listeners.push(fn); },
  };
})();
