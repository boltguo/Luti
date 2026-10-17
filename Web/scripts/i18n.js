/* English comes from index.html. Load before main.js and hero.js. */

(() => {
  const ZH = {
    'meta.title': 'Luti — 云端 AI，连到你的 Mac',
    'meta.desc': 'Luti 通过 MCP 将云端 AI 连接到你的 Mac。在选定的项目文件夹中共享项目记忆、识别技术栈、读写代码、运行构建与测试、操控 Chrome 预览。',
    'meta.og': 'Luti 通过 MCP 将云端 AI 连接到你的 Mac。在选定的项目文件夹中共享项目记忆、识别技术栈、读写代码、运行构建与测试、操控 Chrome 预览。',

    'nav.caps': '本机能力',
    'nav.security': '隐私与控制',
    'nav.download': '下载',
    'a11y.lang': '界面语言',
    'a11y.github': 'GitHub 源码',

    'factory.eyebrow': '一个小应用，打开无限可能。',
    'hero.h1': '云端 AI。<br><em>连到你的 Mac。</em>',
    'hero.lede': 'AI 有想法，给它动手的能力。连接你的代码、终端与浏览器，让云端智能在 Mac 上直接落地。',
    'hero.ctaDownload': '下载 Mac 版',
    'hero.ctaChain': '快速开始',
    'factory.requirements': '免费开源 · macOS 14+',
    'hero.sr': '流程示意：ChatGPT、Claude 和 Grok 的请求经由你的专属 Tunnel 到达 Luti 与本机工具。点击任一站点可切换路线。',

    'factory.workspace': '在你的 MAC 上',
    'factory.remote': '随时随地使用 AI',
    'factory.tunnel': '请求送达，结果返回。',
    'factory.memory': '项目记忆',
    'factory.git': '项目与 Git',
    'factory.code': '文件与代码',
    'factory.terminal': '终端',
    'factory.browser': '浏览器',
    'factory.artifacts': '产物',
    'factory.ask.memory': '记录采用 SQLite 的架构决策',
    'factory.act.memory': 'memory_action · 写入 architecture.md',
    'factory.reply.memory': '✓ 已更新 MEMORY.md 与 architecture.md',
    'factory.ask.git': '了解项目栈并检查 Git 状态',
    'factory.act.git': 'git_query · 发现 3 个修改文件',
    'factory.reply.git': '✓ vite · pnpm · 3 个已修改文件',
    'factory.ask.code': '修改 queue.ts，接入 SQLite',
    'factory.act.code': '修改代码 · queue.ts (+12 −3)',
    'factory.reply.code': '✓ 已更新 queue.ts (+12 −3)',
    'factory.ask.terminal': '运行 pnpm test 检查测试',
    'factory.act.terminal': '执行测试 · 18 passed ✓',
    'factory.reply.terminal': '✓ 测试通过 · 18 passed',
    'factory.ask.browser': '打开预览页面并截个图',
    'factory.act.browser': '正在截图 · localhost:5173',
    'factory.reply.browser': '✓ 预览截图已返回 (214 KB)',
    'factory.ask.artifacts': '导出预览报告 PDF 与构建产物',
    'factory.act.artifacts': 'export_artifact · preview-report.pdf',
    'factory.reply.artifacts': '✓ 已导出产物 preview-report.pdf',
    'factory.act.luti': '分发调用',

    'caps.label': '本机能力',
    'caps.title': '从修改代码，到验证运行效果。',
    'caps.lede': '内置 24 个专为软件工程打造的 MCP 工具。AI 在云端思考与规划，Luti 在你的 Mac 上精准执行并沉淀项目记忆。',
    'caps.task1': '项目记忆',
    'caps.body1': '按项目维护 MEMORY.md 索引与独立主题 .md 决策文档，跨 AI 客户端共享架构背景与关键约定。',
    'caps.task2': '了解项目与 Git',
    'caps.body2': '自动识别技术栈、框架与运行时状态。以只读方式查询 Git 状态、差异、提交历史和 blame。',
    'caps.task3': '读写与修改代码',
    'caps.body3': '在当前项目文件夹内浏览目录、全文搜索、查询符号与诊断信息，并执行结构化精准修改。',
    'caps.task4': '运行构建与测试',
    'caps.body4': '将构建、测试套件和开发服务器作为受控后台任务运行。随时查看实时日志、响应交互提示或终止进程。',
    'caps.task5': '在 Chrome 中真机验证',
    'caps.body5': '打开本机预览页面，模拟点击与表单交互，生成截图或 PDF，并检查控制台报错、网络请求与弹窗。',
    'caps.task6': '交换构建与验证产物',
    'caps.body6': '将截图、PDF 与构建产物作为 MCP 资源直接返回给 AI 对话，或将生成的文件导入回本地项目目录。',

    'tools.all': '全部 24 个 MCP 工具',
    'tools.t1': '项目记忆',
    'tools.t2': '项目',
    'tools.t3': '文件与代码',
    'tools.t4': '进程与任务',
    'tools.t5': 'Git',
    'tools.t6': '浏览器',
    'tools.t8': '产物',

    'sec.label': '隐私与控制',
    'sec.title': '你的 Mac，由你做主。',
    'sec.lede': '开放哪个文件夹、允许哪种连接、何时停止运行，始终由你在本机掌控。',
    'sec.r1': '一次只开放一个文件夹',
    'sec.r1b': '所有工具调用严格限定在你在 Mac 上选定的单个项目文件夹内。切换项目时，旧项目的后台任务、浏览器会话和产物自动关闭。',
    'sec.r2': '专属通道直连，本机确认授权',
    'sec.r2b': '通过你自己的 OpenAI Secure MCP Tunnel 或 Cloudflare Tunnel 接入，支持项目绑定的 OAuth 与本机验证码确认。凭据安全保存在 macOS 钥匙串。',
    'sec.r3': '无中转云服务，零仓库污染',
    'sec.r3b': '数据在 AI 客户端与你的 Mac 之间直接传输。Luti 不设自营中转服务器，无需注册账号，也不会向你的代码仓库写入任何运行时文件。',
    'sec.r4': '关掉就是彻底关掉',
    'sec.r4b': '随时停止运行时，立即断开所有远程通道，并清理正在运行的后台进程与浏览器会话。',

    'start.label': '快速开始',
    'start.title': '三步，即刻连通。',
    'start.lede': '几分钟内接入 ChatGPT、Claude、Grok 或任意支持远程 MCP 的客户端。',
    'start.s1': '选择项目文件夹',
    'start.s1b': '下载并打开 Luti，在 Projects 页面选择你要处理的本地文件夹，启动运行时。',
    'start.s2': '开启 Tunnel 连接',
    'start.s2b': '在 Connections 页面启用 OpenAI Secure MCP Tunnel 或 Cloudflare Tunnel。两种通道可同时运行。',
    'start.s3': '在 AI 客户端中发起任务',
    'start.s3b': '将 Luti 添加到你的 AI 客户端，试着让它检查项目结构、运行测试或打开本地预览。',
    'start.c1Title': 'OpenAI Secure MCP Tunnel',
    'start.c1Badge': 'ChatGPT',
    'start.c1Body': '面向 ChatGPT 工作区的私有出站通道，无需公网域名或暴露 HTTPS 端口。在 Luti 中填入 Tunnel ID 与 Runtime API Key，即可在 ChatGPT 开发者模式中直接选用。',
    'start.c1Link': 'OpenAI Tunnel 配置指南',
    'start.c2Title': 'Cloudflare Tunnel',
    'start.c2Badge': 'HTTPS · OAuth',
    'start.c2Body': '通过你自己的域名（<code>/mcp</code>）提供标准远程 MCP 接入，支持 Claude、Grok、ChatGPT 等客户端。每次连接均绑定当前项目，并需在 Mac 上输入验证码批准。',
    'start.c2Link': 'Cloudflare Tunnel 配置指南',

    'footer.tagline': '云端智能，本机执行。专为 macOS 打造。',
    'footer.product': '产品',
    'footer.source': 'GitHub 源码',
    'footer.hosts': 'AI 客户端',
    'footer.entrances': '连接方式',
    'footer.support': '请我喝杯咖啡',
    'footer.legal': '© 2026 Luti · 基于 Apache-2.0 免费开源',
  };

  const JA = {
    'meta.title': 'Luti — クラウドのAIを、あなたのMacへ。',
    'meta.desc': 'LutiはMCPを通じてクラウドAIとMacを直結。選択したプロジェクトフォルダ内で、プロジェクトメモリの共有、コード編集、ビルドとテスト、Chrome操作をローカル実行します。',
    'meta.og': 'LutiはMCPを通じてクラウドAIとMacを直結。選択したプロジェクトフォルダ内で、プロジェクトメモリの共有、コード編集、ビルドとテスト、Chrome操作をローカル実行します。',

    'nav.caps': '機能',
    'nav.security': 'プライバシーと制御',
    'nav.download': 'ダウンロード',
    'a11y.lang': '表示言語',
    'a11y.github': 'GitHubのソース',

    'factory.eyebrow': '小さなアプリ。広がる可能性。',
    'hero.h1': 'クラウドのAIが、<br><em>あなたのMacに。</em>',
    'hero.lede': 'AIのアイデアを、あなたのMacで形に。コード、ターミナル、ブラウザをつないで、考えるだけから実行へ。',
    'hero.ctaDownload': 'Mac版をダウンロード',
    'hero.ctaChain': 'はじめる',
    'factory.requirements': '無料・オープンソース · macOS 14以降',
    'hero.sr': '動作イメージ：ChatGPT、Claude、Grokのメッセージがトンネルを通り、Lutiとローカルツールへ届きます。',

    'factory.workspace': 'あなたの MAC で',
    'factory.remote': 'どこからでも AI を',
    'factory.tunnel': 'リクエストを届け、結果を返す。',
    'factory.memory': 'メモリ',
    'factory.git': 'プロジェクトとGit',
    'factory.code': 'ファイルとコード',
    'factory.terminal': 'ターミナル',
    'factory.browser': 'ブラウザ',
    'factory.artifacts': '成果物',
    'factory.ask.memory': 'SQLite 採用の設計判断をメモリに記録',
    'factory.act.memory': 'memory_action · architecture.md を保存',
    'factory.reply.memory': '✓ MEMORY.md と architecture.md を更新',
    'factory.ask.git': 'プロジェクト構成と Git の状態を確認',
    'factory.act.git': 'git_query · 変更ファイル 3 件',
    'factory.reply.git': '✓ vite · pnpm · 変更ファイル 3 件',
    'factory.ask.code': 'queue.ts を SQLite 用に編集',
    'factory.act.code': 'コード編集 · queue.ts (+12 −3)',
    'factory.reply.code': '✓ queue.ts を更新 (+12 −3)',
    'factory.ask.terminal': 'pnpm test を実行して確認',
    'factory.act.terminal': 'テスト実行 · 18 passed ✓',
    'factory.reply.terminal': '✓ 全 18 件のテストが成功',
    'factory.ask.browser': 'プレビューを開いてスクショ',
    'factory.act.browser': 'スクショ撮影 · localhost:5173',
    'factory.reply.browser': '✓ スクショを返送 (214 KB)',
    'factory.ask.artifacts': 'プレビュー PDF と成果物を書き出す',
    'factory.act.artifacts': 'export_artifact · preview-report.pdf',
    'factory.reply.artifacts': '✓ preview-report.pdf を出力完了',
    'factory.act.luti': 'ツール転送',

    'caps.label': 'ローカル機能',
    'caps.title': 'コードの変更から、動作の確認まで。',
    'caps.lede': '開発ワークフローのために設計された24のMCPツール。AIがクラウドで考え、LutiがMac上で実行しプロジェクトメモリを保持します。',
    'caps.task1': 'プロジェクトメモリ',
    'caps.body1': 'MEMORY.md インデックスとトピック別 .md 決定ファイルでAI間の文脈を共有し、設計判断や規約を会話をまたいで保持します。',
    'caps.task2': 'プロジェクトと Git の確認',
    'caps.body2': '技術スタック、フレームワーク、ランタイム状態を自動検出。Git の状態・差分・履歴・blame を読み取り専用で確認します。',
    'caps.task3': 'コードの読み書きと編集',
    'caps.body3': '選択したフォルダ内でディレクトリ参照、全文検索、シンボルと診断の照会、構造化されたコード編集を行います。',
    'caps.task4': 'ビルドとテストの実行',
    'caps.body4': 'ビルド、テスト、開発サーバーをバックグラウンドジョブとして実行。ログの確認、対話プロンプトへの応答、停止も自在です。',
    'caps.task5': 'Chrome で実際の画面を検証',
    'caps.body5': 'ローカルプレビューを開き、UI操作、スクリーンショットやPDFの取得、コンソールや通信・ダイアログの確認を行います。',
    'caps.task6': '成果物の受け渡し',
    'caps.body6': 'スクリーンショット、PDF、ビルド成果物を MCP リソースとして AI 会話へ返し、生成ファイルをプロジェクトへ取り込みます。',

    'tools.all': '全 24 個の MCP ツール',
    'tools.t1': 'メモリ',
    'tools.t2': 'プロジェクト',
    'tools.t3': 'ファイルとコード',
    'tools.t4': 'プロセスとジョブ',
    'tools.t5': 'Git',
    'tools.t6': 'ブラウザ',
    'tools.t8': '成果物',

    'sec.label': 'プライバシーと制御',
    'sec.title': 'あなたのMac。あなたのルール。',
    'sec.lede': '開くフォルダ、接続の承認、ランタイムの停止まで、すべてMac上でコントロールできます。',
    'sec.r1': '一度にひとつのフォルダだけ',
    'sec.r1b': 'ツールはMac上で選択した単一のプロジェクトフォルダ内でのみ動作します。切り替えると、実行中のジョブ、ブラウザセッション、成果物は即座に閉じられます。',
    'sec.r2': '専用トンネルとMac上での承認',
    'sec.r2b': '自身のOpenAI Secure MCP Tunnel、またはプロジェクト紐付けOAuthと確認コードを備えたCloudflare Tunnelで接続。認証情報はmacOSキーチェーンに保存されます。',
    'sec.r3': '中継クラウドなし。リポジトリを汚さない',
    'sec.r3b': '通信はAIクライアントとMacの間で直接行われます。Luti独自のサーバーやアカウントは不要で、リポジトリにメタデータを書き込むこともありません。',
    'sec.r4': 'オフは、完全にオフ',
    'sec.r4b': 'ランタイムを停止すると、すべてのトンネル接続、バックグラウンドプロセス、ブラウザセッションが即座に終了します。',

    'start.label': 'はじめる',
    'start.title': '3つのステップで、すぐに開始。',
    'start.lede': 'ChatGPT、Claude、Grokなど、リモートMCP対応クライアントを数分で接続できます。',
    'start.s1': 'プロジェクトフォルダを選ぶ',
    'start.s1b': 'Lutiをダウンロードし、Projectsで作業したいフォルダを選択してランタイムを起動します。',
    'start.s2': 'トンネル接続を有効にする',
    'start.s2b': 'ConnectionsでOpenAI Secure MCP TunnelまたはCloudflare Tunnelを有効化します。両方の同時利用も可能です。',
    'start.s3': 'AIクライアントからタスクを依頼',
    'start.s3b': 'AIクライアントにLutiを追加し、プロジェクトの確認、テストの実行、ローカルプレビューの検証を依頼します。',
    'start.c1Title': 'OpenAI Secure MCP Tunnel',
    'start.c1Badge': 'ChatGPT',
    'start.c1Body': 'ChatGPTワークスペース向けのプライベートなアウトバウンド接続。公開ドメインやHTTPSエンドポイントは不要です。Tunnel IDとRuntime API Keyを入力するだけで利用できます。',
    'start.c1Link': 'OpenAI Tunnel 設定ガイド',
    'start.c2Title': 'Cloudflare Tunnel',
    'start.c2Badge': 'HTTPS · OAuth',
    'start.c2Body': '独自ドメイン（<code>/mcp</code>）でClaude、Grok、ChatGPTなどのOAuthクライアントを接続。接続は選択中のプロジェクトに紐付き、Mac上の確認コードで承認します。',
    'start.c2Link': 'Cloudflare Tunnel 設定ガイド',

    'footer.tagline': 'クラウドの知性、ローカルの実行力。macOSのために設計。',
    'footer.product': '製品',
    'footer.source': 'GitHubのソース',
    'footer.hosts': 'AIクライアント',
    'footer.entrances': '接続方式',
    'footer.support': 'コーヒーを一杯おごる',
    'footer.legal': '© 2026 Luti · Apache-2.0 のもとで無料・オープンソース',
  };

  /* Metadata and factory toast strings without direct HTML nodes. */
  const EN = {
    'meta.title': 'Luti — Cloud AI, on your Mac.',
    'meta.desc': 'Luti connects cloud AI to your Mac through MCP. Share project memory, inspect & edit code, run builds and tests, and automate Chrome — all within the folder you choose.',
    'meta.og': 'Luti connects cloud AI to your Mac through MCP. Share project memory, inspect & edit code, run builds and tests, and automate Chrome — all within the folder you choose.',
    'factory.ask.memory': 'Save SQLite architecture decision',
    'factory.act.memory': 'memory_action · wrote architecture.md',
    'factory.reply.memory': '✓ Saved to MEMORY.md & architecture.md',
    'factory.ask.git': 'Inspect project & Git status',
    'factory.act.git': 'git_query · 3 modified files',
    'factory.reply.git': '✓ vite · pnpm · 3 modified files',
    'factory.ask.code': 'Edit src/queue.ts for SQLite',
    'factory.act.code': 'Edited queue.ts · +12 −3',
    'factory.reply.code': '✓ Updated queue.ts (+12 −3)',
    'factory.ask.terminal': 'Run pnpm test suite',
    'factory.act.terminal': 'pnpm test · 18 passed ✓',
    'factory.reply.terminal': '✓ All 18 tests passed',
    'factory.ask.browser': 'Open preview & take screenshot',
    'factory.act.browser': 'Screenshot · localhost:5173',
    'factory.reply.browser': '✓ Screenshot returned (214 KB)',
    'factory.ask.artifacts': 'Export preview PDF & build bundle',
    'factory.act.artifacts': 'export_artifact · preview-report.pdf',
    'factory.reply.artifacts': '✓ Exported preview-report.pdf',
    'factory.act.luti': 'Routing',
  };

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
