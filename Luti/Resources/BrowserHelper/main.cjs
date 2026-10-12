'use strict';
// JSON-RPC over stdio only. This helper owns its isolated browser, never the user's profile.
const { chromium } = require(process.argv[2]);
const readline = require('node:readline');
const crypto = require('node:crypto');
const path = require('node:path');
const fs = require('node:fs/promises');
const scratch = process.argv[3];
const headless = process.argv[4] === '1';
let browser;
const tabs = new Map();
// Context -> its single close promise. Closing contexts still count toward capacity.
const closingContexts = new Map();
// Downloads that browser_download imports; any other download is cancelled at once.
const claimed = new WeakSet();
// Whole-frame budget, below the native 1 MiB RPC limit.
const frameBudget = 1000000;
const mutating = new Set([
  'browser_open','browser_navigate','browser_click','browser_hover','browser_fill',
  'browser_press','browser_select','browser_check','browser_upload','browser_download',
  'browser_dialog','browser_evaluate','browser_close'
]);
const precondition = new Set([
  'invalid_url','browser_capacity','tab_not_found','stale_snapshot','stale_dialog',
  'invalid_upload','browser_dialog_pending'
]);
const clip = (s, n = 4096) => String(s).slice(0, n);
function fail(code, message) { throw Object.assign(new Error(message), { code }); }
function webURL(value) {
  const u = new URL(value);
  if (!['http:', 'https:'].includes(u.protocol) || u.username || u.password) fail('invalid_url', 'Only HTTP(S) URLs without embedded credentials are supported.');
  return u.href;
}
async function ensureBrowser() {
  if (!browser) {
    // Keep the pinned Playwright 1.63.0 defaults: Chromium takes the last
    // --disable-features value. Its app-clone hard link triggers App Management
    // for the launching app; an isolated automation session does not need it.
    const disabledFeatures = [
      'AvoidUnnecessaryBeforeUnloadCheckSync', 'DestroyProfileOnBrowserClose',
      'DialMediaRouteProvider', 'GlobalMediaControls', 'HttpsUpgrades', 'LensOverlay',
      'MediaRouter', 'PaintHolding', 'ThirdPartyStoragePartitioning',
      'BlockOriginHeaderModificationOnRedirect', 'Translate', 'AutoDeElevate',
      'OptimizationHints', 'msForceBrowserSignIn', 'msEdgeUpdateLaunchServicesPreferredVersion'
    ];
    const defaultFeatures = '--disable-features=' + disabledFeatures.join(',');
    browser = await chromium.launch({
      channel: 'chrome', headless, chromiumSandbox: true, downloadsPath: scratch,
      ignoreDefaultArgs: [defaultFeatures],
      args: [defaultFeatures + ',MacAppCodeSignClone']
    });
    browser.on('disconnected', () => { browser = undefined; tabs.clear(); });
  }
}
const push = (list, entry) => {
  if (!list) return;
  list.push({ time: new Date().toISOString(), ...entry });
  if (list.length > 200) list.shift();
};
function stateForPage(page) {
  for (const state of tabs.values()) if (state.page === page) return state;
  return undefined;
}
function dialogRows(state) {
  return [...state.pendingDialogs.values()].map(item => item.meta);
}
function registerPage(context, page) {
  if (tabs.size >= 4) return undefined;
  const id = 'tab_' + crypto.randomUUID();
  const state = {
    id, context, page, console: [], network: [], requests: [], requestMeta: new WeakMap(),
    refs: new Set(), snapshotId: null, captured: 0,
    pendingDialogs: new Map(), dialogWaiters: new Set()
  };
  tabs.set(id, state);
  page.on('console', msg => {
    if (['log','warning','error','info'].includes(msg.type())) {
      push(state.console, { level: msg.type(), text: clip(msg.text()), location: { ...msg.location(), url: cleanURL(msg.location().url) } });
    }
  });
  page.on('pageerror', error => push(state.console, { level: 'pageerror', text: clip(error.message) }));
  page.on('request', req => {
    state.requestMeta.set(req, {
      requestId: 'request_' + crypto.randomUUID(),
      started: Date.now(),
      method: clip(req.method(), 32),
      url: cleanURL(req.url()),
      resourceType: clip(req.resourceType(), 64)
    });
  });
  page.on('requestfailed', req => {
    const meta = state.requestMeta.get(req) || {
      requestId: 'request_' + crypto.randomUUID(), started: Date.now(),
      method: clip(req.method(), 32), url: cleanURL(req.url()), resourceType: clip(req.resourceType(), 64)
    };
    const error = clip(req.failure()?.errorText || '', 512);
    push(state.network, { kind: 'requestfailed', url: meta.url, error });
    push(state.requests, {
      requestId: meta.requestId, method: meta.method, url: meta.url,
      resourceType: meta.resourceType, status: null,
      durationMs: Math.max(0, Date.now() - meta.started), failed: true, error
    });
  });
  page.on('response', response => {
    const req = response.request();
    const meta = state.requestMeta.get(req) || {
      requestId: 'request_' + crypto.randomUUID(), started: Date.now(),
      method: clip(req.method(), 32), url: cleanURL(response.url()), resourceType: clip(req.resourceType(), 64)
    };
    const status = response.status();
    if (status >= 400) push(state.network, { kind: 'http', url: meta.url, status });
    push(state.requests, {
      requestId: meta.requestId, method: meta.method, url: meta.url,
      resourceType: meta.resourceType, status,
      durationMs: Math.max(0, Date.now() - meta.started), failed: false
    });
  });
  page.on('framenavigated', () => { state.refs.clear(); state.snapshotId = null; });
  page.on('dialog', dialog => {
    state.refs.clear(); state.snapshotId = null;
    const meta = {
      dialogId: 'dialog_' + crypto.randomUUID(),
      type: clip(dialog.type(), 32),
      message: clip(dialog.message(), 4096),
      defaultValue: clip(dialog.defaultValue(), 4096)
    };
    state.pendingDialogs.set(meta.dialogId, { dialog, meta });
    push(state.console, { level: 'browser', text: clip('Dialog pending: ' + meta.type + ' ' + meta.message, 4096) });
    for (const waiter of state.dialogWaiters) waiter(meta);
    state.dialogWaiters.clear();
  });
  // Emission is synchronous: by the next turn browser_download's predicate has claimed it.
  page.on('download', download => {
    setImmediate(() => { if (!claimed.has(download)) discard(download); });
  });
  page.on('close', () => forget(state));
  return state;
}
// Every way a page goes away (tool close, native window close, page self-close)
// ends here. Idempotent; the last owned page of a context closes that context.
function forget(state) {
  if (tabs.delete(state.id)) {
    const shared = [...tabs.values()].some(item => item.context === state.context);
    if (!shared) closeContext(state.context);
  }
  return closingContexts.get(state.context);
}
function closeContext(context) {
  if (!closingContexts.has(context)) {
    closingContexts.set(context, context.close().catch(() => {})
      .finally(() => closingContexts.delete(context)));
  }
  return closingContexts.get(context);
}
function discard(download) {
  download.cancel().catch(() => {}).finally(() => download.delete().catch(() => {}));
}
// Newest entries first in priority, bounded by serialized bytes rather than count.
function recent(list, limit) {
  const rows = [];
  let bytes = 0;
  for (let i = list.length - 1; i >= 0 && rows.length < limit; i--) {
    const size = Buffer.byteLength(JSON.stringify(list[i])) + 1;
    if (bytes + size > 524288) break;
    rows.push(list[i]);
    bytes += size;
  }
  rows.reverse();
  return { entries: rows, truncated: rows.length < Math.min(limit, list.length) };
}
function nextDialog(state) {
  let active = true;
  let resolvePromise;
  const listener = meta => {
    if (!active) return;
    active = false;
    resolvePromise(meta);
  };
  const promise = new Promise(resolve => { resolvePromise = resolve; state.dialogWaiters.add(listener); });
  return {
    promise,
    cancel: () => { active = false; state.dialogWaiters.delete(listener); }
  };
}
async function actionWithDialog(state, action) {
  if (state.pendingDialogs.size) fail('browser_dialog_pending', 'Handle the pending browser dialog before another page action.');
  const waiter = nextDialog(state);
  const actionPromise = Promise.resolve().then(action);
  try {
    const outcome = await Promise.race([
      actionPromise.then(value => ({ kind: 'done', value })),
      waiter.promise.then(meta => ({ kind: 'dialog', meta }))
    ]);
    if (outcome.kind === 'done') {
      waiter.cancel();
      return { value: outcome.value };
    }
    actionPromise.catch(() => {});
    return { dialog: outcome.meta };
  } catch (error) {
    waiter.cancel();
    throw error;
  }
}
async function verifyPostCondition(state, args) {
  const kind = args.waitForText
    ? 'text'
    : (args.waitForUrlContains ? 'urlContains' : (args.waitForState ? 'state' : null));
  if (!kind) return null;
  const expected = args.waitForText || args.waitForUrlContains || args.waitForState;
  const timeout = args.waitTimeoutMs || 5000;
  const started = Date.now();
  try {
    if (kind === 'text') {
      await state.page.getByText(args.waitForText, { exact: false }).first()
        .waitFor({ state: 'visible', timeout });
    } else if (kind === 'urlContains') {
      await state.page.waitForURL(url => url.toString().includes(args.waitForUrlContains), { timeout });
    } else {
      await state.page.waitForLoadState(args.waitForState, { timeout });
    }
    return {
      postConditionKind: kind, postConditionMatched: clip(expected, 4096),
      postConditionSatisfied: true, postConditionWaitedMs: Math.max(0, Date.now() - started)
    };
  } catch (error) {
    return {
      postConditionKind: kind, postConditionMatched: clip(expected, 4096),
      postConditionSatisfied: false, postConditionWaitedMs: Math.max(0, Date.now() - started),
      postConditionError: clip(error?.message || 'Post-condition was not observed.', 512)
    };
  }
}
async function actionResult(state, outcome, args = {}, extra = {}) {
  if (outcome.dialog) {
    return {
      tabId: state.id, acted: true, submitted: true, effect: 'submitted',
      blockedByDialog: true, pendingDialog: outcome.dialog, ...extra
    };
  }
  const verification = await verifyPostCondition(state, args);
  if (!verification) {
    return {
      tabId: state.id, acted: true, submitted: true, effect: 'submitted',
      observeAgain: true, ...extra
    };
  }
  return {
    tabId: state.id, acted: true, submitted: true,
    effect: verification.postConditionSatisfied ? 'confirmed' : 'submitted',
    observeAgain: true, ...verification, ...extra
  };
}
async function closeOwnedTab(state) {
  if (!state.page.isClosed()) await state.page.close({ runBeforeUnload: false });
  await forget(state);
  return { closed: true, tabId: state.id };
}
async function addTab(args) {
  if (tabs.size + closingContexts.size >= 4) fail('browser_capacity', 'Close a tab before opening another; maximum four tabs.');
  await ensureBrowser();
  const context = await browser.newContext({ viewport: { width: args.width || 1440, height: args.height || 900 }, acceptDownloads: true });
  // Any failure after creation releases the context and every tab it registered.
  try {
    context.setDefaultTimeout(10000);
    context.setDefaultNavigationTimeout(15000);
    const page = await context.newPage();
    const state = registerPage(context, page);
    if (!state) fail('browser_capacity', 'Close a tab before opening another; maximum four tabs.');
    context.on('page', popup => {
      if (stateForPage(popup)) return;
      const popupState = registerPage(context, popup);
      if (!popupState) {
        push(state.console, { level: 'browser', text: 'Popup closed because the four-tab capacity is already in use.' });
        popup.close().catch(() => {});
        return;
      }
      push(state.console, { level: 'browser', text: 'Popup adopted as owned tab ' + popupState.id + '.' });
    });
    const outcome = await actionWithDialog(state, async () => {
      await page.goto(webURL(args.url), { waitUntil: 'domcontentloaded' });
      return clip(await page.title(), 512);
    });
    if (outcome.dialog) return actionResult(state, outcome, args, { url: cleanURL(page.url()) });
    return { tabId: state.id, url: cleanURL(page.url()), title: outcome.value };
  } catch (error) {
    for (const [id, item] of tabs) if (item.context === context) tabs.delete(id);
    await closeContext(context);
    throw error;
  }
}
function cleanURL(value) {
  try { const u = new URL(value); u.username = ''; u.password = ''; u.search = ''; u.hash = ''; return u.href; } catch { return ''; }
}
async function target(state, args) {
  if (!state.snapshotId || args.snapshotId !== state.snapshotId || Date.now() - state.captured > 60000 || !state.refs.has(args.ref)) fail('stale_snapshot', 'Take a fresh browser_observe(action=snapshot) and use its snapshotId and ref.');
  for (const frame of state.page.frames()) {
    const locator = frame.locator('aria-ref=' + args.ref);
    if (await locator.count() === 1) return locator;
  }
  fail('stale_snapshot', 'The referenced element is no longer present. Observe again.');
}
async function scopeTarget(state, args) {
  if (!args.scopeSnapshotId && !args.scopeRef) return null;
  return target(state, { snapshotId: args.scopeSnapshotId, ref: args.scopeRef });
}
async function dispatch(method, args) {
  if (method === 'browser_open') return addTab(args);
  if (method === 'browser_tabs') {
    const rows = [];
    for (const state of tabs.values()) {
      if (!state.page.isClosed()) rows.push({
        tabId: state.id, url: cleanURL(state.page.url()),
        title: state.pendingDialogs.size ? '' : clip(await state.page.title(), 512),
        pendingDialogCount: state.pendingDialogs.size
      });
    }
    return { tabs: rows };
  }
  if (method === 'shutdown') { await browser?.close(); return { closed: true }; }
  const state = tabs.get(args.tabId);
  if (!state) fail('tab_not_found', 'Use a tabId returned by browser_session(action=open).');
  const page = state.page;
  if (state.pendingDialogs.size && ![
    'browser_dialog','browser_snapshot','browser_console','browser_network_errors','browser_network','browser_close'
  ].includes(method)) {
    fail('browser_dialog_pending', 'Handle the pending browser dialog before another page operation.');
  }
  switch (method) {
    case 'browser_navigate': {
      state.refs.clear(); state.snapshotId = null;
      const outcome = await actionWithDialog(
        state, () => page.goto(webURL(args.url), { waitUntil: 'domcontentloaded' }));
      const extra = { url: cleanURL(page.url()) };
      if (!outcome.dialog) extra.title = clip(await page.title(), 512);
      return await actionResult(state, outcome, args, extra);
    }
    case 'browser_snapshot': {
      const pendingDialogs = dialogRows(state);
      if (pendingDialogs.length) {
        state.refs.clear(); state.snapshotId = null; state.captured = 0;
        return {
          tabId: state.id, url: cleanURL(page.url()), blockedByDialog: true,
          pendingDialogs, snapshot: '', truncated: false
        };
      }
      const scoped = await scopeTarget(state, args);
      const depth = args.depth || 12;
      const raw = scoped
        ? await scoped.ariaSnapshot({ mode: 'ai', depth, timeout: 10000 })
        : await page.ariaSnapshot({ mode: 'ai', depth, timeout: 10000 });
      const snapshot = clip(raw, 60000);
      state.refs = new Set([...snapshot.matchAll(/\[ref=([a-zA-Z0-9]+)\]/g)].map(m => m[1]));
      state.snapshotId = crypto.randomUUID(); state.captured = Date.now();
      return {
        tabId: state.id, snapshotId: state.snapshotId, expiresAfterSeconds: 60,
        url: cleanURL(page.url()), snapshot, truncated: raw.length > snapshot.length,
        scoped: !!scoped, scopeRef: scoped ? args.scopeRef : null, pendingDialogs: []
      };
    }
    case 'browser_click': {
      const locator = await target(state, args);
      state.refs.clear(); state.snapshotId = null;
      return await actionResult(
        state, await actionWithDialog(state, () => locator.click()), args);
    }
    case 'browser_fill': {
      const locator = await target(state, args);
      state.refs.clear(); state.snapshotId = null;
      return await actionResult(
        state, await actionWithDialog(state, () => locator.fill(args.text)), args);
    }
    case 'browser_press': {
      const locator = await target(state, args);
      state.refs.clear(); state.snapshotId = null;
      return await actionResult(
        state, await actionWithDialog(state, () => locator.press(args.key)), args);
    }
    case 'browser_select': {
      const locator = await target(state, args);
      state.refs.clear(); state.snapshotId = null;
      const outcome = await actionWithDialog(state, () => locator.selectOption(args.value));
      return await actionResult(
        state, outcome, args, outcome.dialog ? {} : { selected: outcome.value });
    }
    case 'browser_check': {
      const locator = await target(state, args);
      state.refs.clear(); state.snapshotId = null;
      const outcome = await actionWithDialog(state, () => args.checked === false ? locator.uncheck() : locator.check());
      return await actionResult(
        state, outcome, args, { checked: args.checked !== false });
    }
    case 'browser_hover': {
      const locator = await target(state, args);
      state.refs.clear(); state.snapshotId = null;
      return await actionResult(
        state, await actionWithDialog(state, () => locator.hover()), args);
    }
    case 'browser_upload': {
      const locator = await target(state, args);
      const root = path.resolve(scratch) + path.sep;
      const upload = path.resolve(args.uploadPath || '');
      if (!upload.startsWith(root)) fail('invalid_upload', 'Upload staging path is outside private browser storage.');
      const stat = await fs.stat(upload);
      if (!stat.isFile() || stat.size > 33554432) fail('invalid_upload', 'Upload file must be a regular file up to 32 MiB.');
      state.refs.clear(); state.snapshotId = null;
      return await actionResult(
        state, await actionWithDialog(state, () => locator.setInputFiles(upload)), args);
    }
    case 'browser_download': {
      const locator = await target(state, args);
      state.refs.clear(); state.snapshotId = null;
      let download;
      // Claimed synchronously on emission, before the page-level discard can run.
      const emitted = page.waitForEvent('download', { timeout: 15000, predicate: item => { claimed.add(item); return true; } });
      try {
        [download] = await Promise.all([emitted, locator.click()]);
      } catch {
        // A download that arrived before, or arrives after, the failed click is ours to discard.
        emitted.then(discard, () => {});
        fail('browser_outcome_unknown', 'The click did not produce a confirmed download; observe before any retry.');
      }
      // Playwright keeps the original until its context closes; always release it here.
      try {
        const failure = await download.failure();
        if (failure) fail('browser_operation_failed', clip(failure, 1024));
        const source = await download.path();
        const original = await fs.stat(source);
        if (!original.isFile() || original.size > 33554432) fail('download_too_large', 'Downloaded file exceeds 32 MiB.');
        const suggestedName = clip(path.basename(download.suggestedFilename() || 'download'), 255);
        const filename = crypto.randomUUID();
        await download.saveAs(path.join(scratch, filename));
        return { tabId: state.id, filename, suggestedName, url: cleanURL(page.url()) };
      } finally {
        await download.delete().catch(() => {});
      }
    }
    case 'browser_wait': {
      state.refs.clear(); state.snapshotId = null;
      const timeout = args.timeoutMs || 10000;
      if (args.text) {
        await page.getByText(args.text, { exact: false }).first().waitFor({ state: 'visible', timeout });
        return { tabId: state.id, waitedFor: 'text', matched: clip(args.text, 4096), url: cleanURL(page.url()), title: clip(await page.title(), 512) };
      }
      if (args.urlContains) {
        await page.waitForURL(url => url.toString().includes(args.urlContains), { timeout });
        return { tabId: state.id, waitedFor: 'urlContains', matched: clip(args.urlContains, 4096), url: cleanURL(page.url()), title: clip(await page.title(), 512) };
      }
      await page.waitForLoadState(args.state || 'load', { timeout });
      return { tabId: state.id, waitedFor: args.state || 'load', url: cleanURL(page.url()), title: clip(await page.title(), 512) };
    }
    case 'browser_screenshot': {
      const scoped = await scopeTarget(state, args);
      const size = scoped
        ? await scoped.boundingBox()
        : await page.evaluate(() => ({ width: Math.max(document.documentElement.scrollWidth, innerWidth), height: Math.max(document.documentElement.scrollHeight, innerHeight) }));
      if (!size) fail('stale_snapshot', 'The scoped element is no longer visible. Take a fresh browser_observe(action=snapshot).');
      // Budget rendered pixels before capture: scoped elements can be as large as full pages.
      if (scoped || args.fullPage) {
        const scale = await page.evaluate(() => window.devicePixelRatio || 1);
        const pixels = size.width * size.height * scale * scale;
        if (!(size.width <= 10000 && size.height <= 16000 && pixels <= 40000000)) {
          fail('screenshot_too_large', scoped
            ? 'Element screenshot exceeds 40 megapixels; scope a smaller element.'
            : 'Full-page screenshot exceeds 40 megapixels; use fullPage=false.');
        }
      }
      const filename = crypto.randomUUID() + '.png';
      const bytes = scoped
        ? await scoped.screenshot({ type: 'png', timeout: 15000 })
        : await page.screenshot({ type: 'png', fullPage: !!args.fullPage, timeout: 15000 });
      if (bytes.length > 33554432) fail('screenshot_too_large', 'Screenshot exceeds 32 MiB.');
      await fs.writeFile(path.join(scratch, filename), bytes, { flag: 'wx', mode: 0o600 });
      return {
        tabId: state.id, filename, url: cleanURL(page.url()),
        scoped: !!scoped, scopeRef: scoped ? args.scopeRef : null
      };
    }
    case 'browser_console': return { tabId: state.id, ...recent(state.console, args.limit || 100) };
    case 'browser_network_errors': return { tabId: state.id, ...recent(state.network, args.limit || 100) };
    case 'browser_network': return { tabId: state.id, ...recent(state.requests, args.limit || 100) };
    case 'browser_dialog': {
      const item = state.pendingDialogs.get(args.dialogId);
      if (!item) fail('stale_dialog', 'The dialog is no longer pending. Take a fresh browser_observe(action=snapshot) before deciding what to do next.');
      state.pendingDialogs.delete(args.dialogId);
      state.refs.clear(); state.snapshotId = null;
      if (args.action === 'accept') await item.dialog.accept(args.promptText || '');
      else await item.dialog.dismiss();
      const verification = await verifyPostCondition(state, args);
      return {
        tabId: state.id, dialogId: args.dialogId, action: args.action, handled: true,
        submitted: true,
        effect: verification?.postConditionSatisfied ? 'confirmed' : 'submitted',
        observeAgain: true, ...(verification || {})
      };
    }
    case 'browser_evaluate': {
      state.refs.clear(); state.snapshotId = null;
      const outcome = await actionWithDialog(state, () => page.evaluate(args.expression));
      if (outcome.dialog) return await actionResult(state, outcome, args);
      const value = outcome.value;
      const encoded = JSON.stringify(value ?? null);
      if (Buffer.byteLength(encoded) > 65536) return { truncated: true, text: clip(encoded, 16000) };
      return { value: value ?? null };
    }
    case 'browser_close': return closeOwnedTab(state);
    default: fail('unknown_method', 'Unknown browser method.');
  }
}
let chain = Promise.resolve();
const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on('line', line => {
  if (Buffer.byteLength(line) > 131072) { process.exitCode = 1; input.close(); return; }
  chain = chain.then(async () => {
    let request;
    try {
      request = JSON.parse(line);
      const result = await dispatch(request.method, request.params || {});
      const frame = JSON.stringify({ jsonrpc: '2.0', id: request.id, result });
      // An oversized frame would close the whole session; report it as a result error instead.
      if (Buffer.byteLength(frame) > frameBudget) fail('browser_response_too_large', 'The browser result exceeded the transport budget; request a smaller range.');
      process.stdout.write(frame + '\n');
    } catch (error) {
      // Action errors can happen after side effects. Preserve that uncertainty explicitly.
      const effect = mutating.has(request?.method) && !precondition.has(error.code) ? 'possible' : 'none';
      process.stdout.write(JSON.stringify({
        jsonrpc: '2.0', id: request?.id ?? null,
        error: { code: error.code || 'browser_operation_failed', message: clip(error.message, 1024), effect }
      }) + '\n');
    }
  });
});
input.on('close', () => { chain.finally(async () => { await browser?.close(); process.exit(); }); });
process.on('SIGTERM', async () => { await browser?.close(); process.exit(); });
