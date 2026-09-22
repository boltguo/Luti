/* Illustrative demo: memory, code edits, browser preview and screenshots. */

(() => {
  const stage = document.getElementById('stage');
  if (!stage) return;

  const $ = id => document.getElementById(id);
  const deck = $('deck');
  /* Exclude decorative cards from the animation. */
  const clients = [...deck.querySelectorAll('.client[data-client]')];
  const byName = Object.fromEntries(clients.map(c => [c.dataset.client, c]));
  const lutiBar = $('nodeLuti');
  const nodes = { tunnel: $('nodeTunnel'), luti: lutiBar };
  /* Shared path for wire rendering and packet positions. */
  const wireBase = $('wireBase');
  const wireTrail = $('wireTrail');
  const tube = ['wireCasing', 'wireBore', 'wireRibs'].map($);
  const wire = $('wire');
  const packets = $('packets');
  const mac = $('mac');
  const screen = $('macScreen');
  const wins = { editor: $('viewEditor'), browser: $('viewBrowser') };

  const ledger = $('viewContext');
  const byLine = Object.fromEntries(
    Object.entries({ ...wins, context: ledger }).map(([k, el]) => [k, el.querySelector('[data-by]')])
  );
  const shot = $('shot');
  const mini = $('miniPreview');
  const statusTool = $('statusTool');
  const statusResult = $('statusResult');
  const urlText = $('urlText');
  const ctxList = $('ctxList');
  const ctxCount = $('ctxCount');
  const linkMode = $('linkMode');
  const hopLink = $('hopLink');
  const hops = Object.fromEntries([...stage.parentElement.querySelectorAll('.hop')].map(h => [h.dataset.hop, h]));
  const hopClient = $('hopClient');
  const toggle = $('stageToggle');
  const toggleIcon = $('toggleIcon');
  const toggleText = $('toggleText');
  const addedLines = [...$('editor').querySelectorAll('[data-add]')];

  const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
  const t = key => (window.lutiI18n ? window.lutiI18n.t(key) : key);

  /* Epoch checks cancel the previous loop after a language change. */
  let epoch = 0;
  const ABORT = Symbol('restart');

  /* Wire geometry */

  let pathLen = 0;
  const marks = { tunnel: 0.33, luti: 0.66 };

  function point(el, ax, ay) {
    const s = stage.getBoundingClientRect();
    const r = el.getBoundingClientRect();
    return { x: r.left - s.left + r.width * ax, y: r.top - s.top + r.height * ay };
  }

  const SAMPLES = 260;

  function nearest(pt) {
    let best = 0, bd = Infinity;
    for (let i = 0; i <= SAMPLES; i++) {
      const l = (pathLen * i) / SAMPLES;
      const q = wireBase.getPointAtLength(l);
      const d = (q.x - pt.x) ** 2 + (q.y - pt.y) ** 2;
      if (d < bd) { bd = d; best = l; }
    }
    return best / pathLen;
  }

  const stackedLane = matchMedia('(max-width: 860px)');

  function layout() {
    const r = stage.getBoundingClientRect();
    if (!r.width || !r.height) return;
    wire.setAttribute('viewBox', `0 0 ${r.width} ${r.height}`);

    // Anchor to the front card, excluding stack padding.
    const face = deck.querySelector('.client[data-pos="0"]') || deck;
    const stacked = stackedLane.matches;
    const from = stacked ? point(face, 0.5, 1) : point(face, 1, 0.5);
    const edge = stacked ? point(screen, 0.5, 0) : point(screen, 0, 0.5);
    // Extend endpoints behind the card and screen to hide the caps.
    const a = stacked ? { x: from.x, y: from.y - 10 } : { x: from.x - 10, y: from.y };
    const z = stacked ? { x: edge.x, y: edge.y + 18 } : { x: edge.x + 18, y: from.y };

    const d = `M ${a.x.toFixed(1)} ${a.y.toFixed(1)} L ${z.x.toFixed(1)} ${z.y.toFixed(1)}`;
    wireBase.setAttribute('d', d);
    wireTrail.setAttribute('d', d);
    pathLen = wireBase.getTotalLength();
    tube.forEach(el => el.setAttribute('d', d));

    marks.tunnel = nearest(point(nodes.tunnel, 0.5, 0.5));
    // Trigger the toolbar as a packet reaches the screen edge.
    marks.luti = Math.min(0.96, nearest(edge));
  }

  /* Pausable clock */

  let userPaused = false;
  let offscreen = false;
  const waiters = [];
  const isPaused = () => userPaused || offscreen || document.hidden;

  function release() {
    if (isPaused()) return;
    while (waiters.length) waiters.pop()();
  }
  const gate = () => (isPaused() ? new Promise(r => waiters.push(r)) : Promise.resolve());
  const sleep = async (ms, e) => {
    await gate();
    if (e !== epoch) throw ABORT;
    await new Promise(r => setTimeout(r, ms));
    if (e !== epoch) throw ABORT;
  };

  /* Move the active client to the front of the stack. */

  let order = ['claude', 'grok', 'codex', 'chatgpt'];

  const seeded = new Map(clients.map(c => [c, c.querySelector('[data-log]').children.length]));

  function focusClient(name) {
    order = [name, ...order.filter(n => n !== name)];
    order.forEach((n, i) => { byName[n].dataset.pos = String(i); });
    const el = byName[name];
    hopClient.textContent = el.querySelector('.client__name').textContent;

    const local = el.dataset.link === 'local';
    const carrier = t(local ? 'stage.linkLocal' : 'stage.linkRemote');
    linkMode.textContent = carrier;
    hopLink.textContent = `MCP · ${carrier}`;
  }

  function addBubble(client, kind, build) {
    const log = client.querySelector('[data-log]');
    const el = document.createElement('p');
    el.className = `bubble bubble--${kind}`;
    build(el);
    log.appendChild(el);
    while (log.children.length > 4) log.firstElementChild.remove();
    return el;
  }

  async function ask(client, text, e) {
    const field = client.querySelector('[data-field]');
    client.classList.add('is-typing');
    field.textContent = '';
    /* Type Latin text faster to keep scene durations comparable. */
    const step = text.length > 26 ? 22 : 34;
    for (const ch of text) {
      await sleep(step, e);
      field.append(ch);
    }
    await sleep(340, e);
    client.classList.add('is-sending');
    await sleep(170, e);
    addBubble(client, 'user', el => { el.textContent = text; });
    field.textContent = '';
    client.classList.remove('is-typing', 'is-sending');
    await sleep(240, e);
  }

  function setHop(name) {
    Object.entries(hops).forEach(([k, el]) => el.classList.toggle('is-on', k === name));
  }
  function pulse(node) {
    node.classList.remove('is-hit');
    void node.offsetWidth;
    node.classList.add('is-hit');
    setTimeout(() => node.classList.remove('is-hit'), 760);
  }

  /* Packet animation */

  const easeInOut = t => (t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2);

  function makeThumb(w, h) {
    const box = document.createElement('span');
    box.className = 'thumb';
    box.style.width = `${w}px`;
    box.style.height = `${h}px`;
    const clone = mini.cloneNode(true);
    clone.removeAttribute('id');
    clone.style.cssText =
      `position:absolute;top:0;left:0;width:300px;height:200px;` +
      `transform:scale(${Math.max(w / 300, h / 200).toFixed(3)});transform-origin:top left;`;
    box.appendChild(clone);
    return box;
  }

  function travel({ e, label, icon, back = false, duration = 1650, thumb = false }) {
    return new Promise((resolve, reject) => {
      const el = document.createElement('div');
      el.className = `packet${back ? ' packet--return' : ''}${thumb ? ' packet--thumb' : ''}`;
      if (thumb) {
        const box = document.createElement('span');
        box.className = 'packet__img';
        box.appendChild(makeThumb(54, 32));
        el.appendChild(box);
      } else {
        el.innerHTML = `<svg aria-hidden="true"><use href="#${icon}"/></svg>`;
        el.append(label);
      }
      packets.appendChild(el);
      wireTrail.classList.toggle('is-back', back);

      const seg = pathLen * 0.24;
      let t = 0;
      let last = null;
      let prev = back ? 1 : 0;

      const frame = now => {
        if (e !== epoch) {
          el.remove();
          wireTrail.style.opacity = '0';
          reject(ABORT);
          return;
        }
        if (last === null) last = now;
        if (!isPaused()) t += now - last;
        last = now;

        const k = Math.min(1, t / duration);
        const u = back ? 1 - easeInOut(k) : easeInOut(k);
        const pt = wireBase.getPointAtLength(u * pathLen);

        el.style.transform = `translate(${pt.x}px, ${pt.y}px) translate(-50%, -50%)`;
        el.style.opacity = k < 0.07 ? String(k / 0.07) : k > 0.84 ? String((1 - k) / 0.16) : '1';

        wireTrail.style.opacity = String(Math.min(1, Math.min(k, 1 - k) * 8));
        wireTrail.style.strokeDasharray = `${seg} ${pathLen}`;
        wireTrail.style.strokeDashoffset = String(back ? seg - (u * pathLen + seg) : seg - u * pathLen);

        const crossed = (m) => (back ? prev > m && u <= m : prev < m && u >= m);
        if (crossed(marks.tunnel)) { pulse(nodes.tunnel); setHop('tunnel'); }
        if (crossed(marks.luti)) { pulse(nodes.luti); setHop('luti'); }
        prev = u;

        if (k < 1) {
          requestAnimationFrame(frame);
        } else {
          el.remove();
          wireTrail.style.opacity = '0';
          resolve();
        }
      };
      requestAnimationFrame(frame);
    });
  }

  let winOrder = ['editor', 'browser'];
  function focusWin(name) {
    winOrder = [name, ...winOrder.filter(n => n !== name)];
    winOrder.forEach((n, i) => { wins[n].dataset.pos = String(i); });
  }

  function drive(name, tool) {
    byLine[name].textContent = tool;
    const el = name === 'context' ? ledger : wins[name];
    if (name !== 'context') focusWin(name);
    el.classList.remove('is-driven');
    void el.offsetWidth;
    el.classList.add('is-driven');
    setTimeout(() => el.classList.remove('is-driven'), 1000);
  }
  function setCall(tool, note) {
    statusTool.textContent = tool;
    statusResult.textContent = note;
    statusResult.className = 'mac__res is-pending';
    lutiBar.classList.add('is-busy');
  }
  function setResult(text) {
    statusResult.textContent = text;
    statusResult.className = 'mac__res is-ok';
    lutiBar.classList.remove('is-busy');
  }

  /* data-new identifies the memory card for recall and reset. */
  function memCard(kind, src, body, cls) {
    const el = document.createElement('article');
    el.className = cls ? `mem ${cls}` : 'mem';
    el.dataset.new = '1';
    const top = document.createElement('p');
    top.className = 'mem__top';
    const k = document.createElement('span');
    k.className = 'mem__kind';
    k.dataset.kind = 'decision';
    k.textContent = kind;
    const sr = document.createElement('span');
    sr.className = 'mem__src';
    sr.textContent = src;
    top.append(k, sr);
    const p = document.createElement('p');
    p.className = 'mem__body';
    p.textContent = body;
    el.append(top, p);
    return el;
  }

  function resetMac() {
    focusWin('editor');
    byLine.context.textContent = 'memory';
    byLine.editor.textContent = 'edit_files';
    byLine.browser.textContent = 'browser_session';
    addedLines.forEach(l => { l.classList.add('is-pending'); l.classList.remove('is-added'); });
    wins.browser.classList.remove('is-loading', 'is-loaded');
    urlText.textContent = 'localhost:5173';
    shot.classList.remove('is-on', 'is-flash');
    ctxList.querySelectorAll('[data-new]').forEach(el => el.remove());
    ctxList.querySelectorAll('.is-match').forEach(el => el.classList.remove('is-match'));
    ctxCount.textContent = t('demo.count');
    setCall('memory', t('demo.idle'));
    lutiBar.classList.remove('is-busy');
  }

  /* Scene 1: save a decision. */
  async function sceneRemember(e) {
    focusClient('claude');
    setHop('client');
    await sleep(520, e);
    await ask(byName.claude, t('demo.askRemember'), e);

    setCall('memory', t('demo.callRemember'));
    await travel({ e, label: 'memory', icon: 'i-brain' });

    setHop('project');
    drive('context', 'memory · remember');
    await sleep(440, e);
    ctxList.prepend(memCard(t('demo.kindDecision'), t('demo.memSrcNew'), t('demo.memNew'), 'is-new'));
    ctxCount.textContent = t('demo.countNew');
    await sleep(820, e);
    setResult('mem_9f3c1 · rev 42');
    await sleep(520, e);

    await travel({ e, label: 'mem_9f3c1', icon: 'i-brain', back: true, duration: 1400 });
    setHop('client');
    addBubble(byName.claude, 'ai', el => {
      el.innerHTML =
        t('demo.replyRemember') +
        '<span class="bubble__file"><svg aria-hidden="true" style="width:11px;height:11px"><use href="#i-brain"/></svg>decision · mem_9f3c1</span>';
    });
    await sleep(1500, e);
  }

  /* Scene 2: recall the decision and edit code. */
  async function sceneApply(e) {
    focusClient('codex');
    setHop('client');
    await sleep(540, e);
    await ask(byName.codex, t('demo.askApply'), e);

    setCall('memory', t('demo.callRecall'));
    await travel({ e, label: 'memory', icon: 'i-brain' });

    setHop('project');
    drive('context', 'memory · recall');
    await sleep(460, e);
    const hit = ctxList.querySelector('[data-new]');
    if (hit) hit.classList.add('is-match');
    await sleep(760, e);
    setResult('1 match · rev 42');
    await sleep(520, e);

    setHop('client');
    setCall('edit_files', t('demo.callEdit'));
    await travel({ e, label: 'edit_files', icon: 'i-pencil', duration: 1350 });

    setHop('project');
    drive('editor', 'edit_files');
    await sleep(340, e);
    for (const line of addedLines) {
      line.classList.remove('is-pending');
      line.classList.add('is-added');
      await sleep(200, e);
    }
    await sleep(280, e);
    setResult('+12 −3 · sha 8f2a91c');
    await sleep(560, e);

    await travel({ e, label: 'queue.ts', icon: 'i-pencil', back: true, duration: 1400 });
    setHop('client');
    addBubble(byName.codex, 'ai', el => {
      el.innerHTML = t('demo.replyApply');
      el.appendChild(recallQuote());
    });
    await sleep(1900, e);
  }

  /* Scene 3: preview the result. */
  async function scenePreview(e) {
    focusClient('grok');
    setHop('client');
    await sleep(540, e);
    await ask(byName.grok, t('demo.askPreview'), e);

    setCall('browser_session', t('demo.callOpen'));
    await travel({ e, label: 'browser_session', icon: 'i-globe' });

    setHop('project');
    drive('browser', 'browser_session');
    await sleep(320, e);
    wins.browser.classList.add('is-loading');
    urlText.textContent = '';
    for (const ch of 'localhost:5173') {
      await sleep(42, e);
      urlText.textContent += ch;
    }
    await sleep(560, e);
    wins.browser.classList.remove('is-loading');
    wins.browser.classList.add('is-loaded');
    await sleep(480, e);
    setResult('networkidle · 1 tab');
    await sleep(480, e);

    await travel({ e, label: 'page state', icon: 'i-eye', back: true, duration: 1400 });
    setHop('client');
    addBubble(byName.grok, 'ai', el => { el.innerHTML = t('demo.replyPreview'); });
    await sleep(1600, e);
  }

  /* Scene 4: return a screenshot. */
  async function sceneShot(e) {
    focusClient('chatgpt');
    setHop('client');
    await sleep(540, e);
    await ask(byName.chatgpt, t('demo.askShot'), e);

    setCall('browser_observe', t('demo.callShot'));
    await travel({ e, label: 'browser_observe', icon: 'i-camera' });

    setHop('project');
    drive('browser', 'browser_observe');
    await sleep(280, e);
    shot.classList.add('is-on');
    await sleep(600, e);
    shot.classList.add('is-flash');
    await sleep(440, e);
    shot.classList.remove('is-on', 'is-flash');
    setResult('image/png · 214 KB');
    await sleep(440, e);

    await travel({ e, label: '', icon: '', back: true, duration: 1550, thumb: true });
    setHop('client');
    addBubble(byName.chatgpt, 'ai', el => {
      el.innerHTML = t('demo.replyShot');
      const box = document.createElement('span');
      box.className = 'bubble__shot';
      box.appendChild(makeThumb(148, 86));
      el.appendChild(box);
    });
    await sleep(2000, e);
  }

  function recallQuote() {
    const box = document.createElement('span');
    box.className = 'bubble__mem';
    const b = document.createElement('b');
    b.textContent = `${t('demo.kindDecision')} · mem_9f3c1 · claude`;
    const body = document.createElement('span');
    body.textContent = t('demo.memNew');
    box.append(b, body);
    return box;
  }

  /* Scene loop */

  async function run() {
    const e = ++epoch;
    try {
      for (;;) {
        resetMac();
        await sceneRemember(e);
        await sceneApply(e);
        await scenePreview(e);
        await sceneShot(e);
        setHop(null);
        await sleep(1100, e);
        clients.forEach(c => {
          const log = c.querySelector('[data-log]');
          while (log.children.length > seeded.get(c)) log.lastElementChild.remove();
        });
      }
    } catch (err) {
      if (err !== ABORT) throw err;
    }
  }

  function restart() {
    epoch++;
    packets.textContent = '';
    wireTrail.style.opacity = '0';
    clients.forEach(c => {
      c.classList.remove('is-typing', 'is-sending');
      c.querySelector('[data-field]').textContent = '';
      const log = c.querySelector('[data-log]');
      while (log.children.length > seeded.get(c)) log.lastElementChild.remove();
    });
    focusClient('claude');
    resetMac();
    setHop(null);
    toggleText.textContent = t(userPaused ? 'demo.resume' : 'demo.pause');
    if (reduceMotion.matches) staticState();
    else run();
  }

  /* Reduced-motion fallback */

  function staticState() {
    focusClient('chatgpt');
    addedLines.forEach(l => { l.classList.remove('is-pending'); l.classList.add('is-added'); });
    byLine.context.textContent = 'memory · recall';
    byLine.editor.textContent = 'edit_files';
    byLine.browser.textContent = 'browser_observe';
    ctxList.prepend(memCard(t('demo.kindDecision'), t('demo.memSrcNew'), t('demo.memNew'), 'is-match'));
    ctxCount.textContent = t('demo.countNew');
    focusWin('browser');
    wins.browser.classList.add('is-loaded');
    setResult('image/png · 214 KB');
    statusTool.textContent = 'browser_observe';
    addBubble(byName.chatgpt, 'user', el => { el.textContent = t('demo.askShot'); });
    addBubble(byName.chatgpt, 'ai', el => {
      el.innerHTML = t('demo.replyShot');
      const box = document.createElement('span');
      box.className = 'bubble__shot';
      box.appendChild(makeThumb(148, 86));
      el.appendChild(box);
    });
    setHop('project');
    toggle.hidden = true;
  }

  layout();
  new ResizeObserver(layout).observe(stage);
  addEventListener('resize', layout);

  toggle.addEventListener('click', () => {
    userPaused = !userPaused;
    toggle.setAttribute('aria-pressed', String(userPaused));
    toggleIcon.setAttribute('href', userPaused ? '#i-play' : '#i-pause');
    toggleText.textContent = t(userPaused ? 'demo.resume' : 'demo.pause');
    release();
  });

  /* Pause while off-screen or in a background tab. */
  new IntersectionObserver(
    ([e]) => { offscreen = !e.isIntersecting; release(); },
    { threshold: 0.08 }
  ).observe(stage);
  document.addEventListener('visibilitychange', release);
  if (window.lutiI18n) window.lutiI18n.on(restart);

  if (reduceMotion.matches) staticState();
  else run();
})();
