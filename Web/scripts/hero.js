/* A hand-built SVG workshop. Bespoke isometric stations, lanes, parcels and
 * gentle building toast bubbles share one coordinate system; each request and
 * its result travel through Tunnel and Luti. */
(() => {
  const factory = document.getElementById('factory');
  if (!factory) return;
  const scene = document.getElementById('factoryScene');
  const laneLayer = document.getElementById('factoryRoutes');
  const packetLayer = document.getElementById('factoryParcels');
  const overlayLayer = document.getElementById('factoryOverlays');
  const stationLayer = document.getElementById('factoryStations');
  const tunnelNode = document.getElementById('factoryTunnel');
  const nodes = [...stationLayer.querySelectorAll('[data-node]')];
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const compact = matchMedia('(max-width: 600px)');
  const NS = 'http://www.w3.org/2000/svg';
  const S = Math.tan(Math.PI / 6);
  const clients = ['chatgpt', 'claude', 'grok'];
  const tools = ['memory', 'git', 'code', 'terminal', 'browser', 'artifacts'];
  const scenarios = [
    { client: 'chatgpt', tool: 'code' },
    { client: 'claude', tool: 'memory' },
    { client: 'chatgpt', tool: 'git' },
    { client: 'grok', tool: 'terminal' },
    { client: 'claude', tool: 'browser' },
    { client: 'grok', tool: 'artifacts' },
  ];
  const toolMeta = {
    memory: { short: 'memory' },
    git: { short: 'git_query' },
    code: { short: 'edit_files' },
    terminal: { short: 'run_process' },
    browser: { short: 'browser_observe' },
    artifacts: { short: 'export_artifact' },
  };
  const palette = {
    chatgpt: { ink: '#237b65', top: '#def2e7', front: '#87c9aa', side: '#54a98a', wash: '#ecf8f0' },
    claude: { ink: '#ba6645', top: '#fbe5d6', front: '#e8ac87', side: '#cc8561', wash: '#fff2e7' },
    grok: { ink: '#475464', top: '#cad3df', front: '#718095', side: '#465467', wash: '#edf1f6' },
    luti: { ink: '#8761b5', top: '#efe2fa', front: '#c7aadf', side: '#a184bf', wash: '#f6edfc' },
    memory: { ink: '#779250', top: '#edf2d9', front: '#bdcf90', side: '#99b273', wash: '#f5f8e9' },
    git: { ink: '#c0634b', top: '#fde7e0', front: '#eaa795', side: '#cf7f6a', wash: '#fff3ef' },
    code: { ink: '#507ebc', top: '#e0edfc', front: '#9cbce9', side: '#729bce', wash: '#eef5fd' },
    terminal: { ink: '#ad8434', top: '#fcf0ce', front: '#e6c578', side: '#c7a054', wash: '#fff8e7' },
    browser: { ink: '#388d99', top: '#d9f2f2', front: '#91cdd0', side: '#5baeb8', wash: '#ecf9f8' },
    artifacts: { ink: '#a45a82', top: '#f8e2ee', front: '#dd9fc0', side: '#bf799f', wash: '#fdf1f7' },
  };
  const t = key => (window.lutiI18n ? window.lutiI18n.t(key) : key);
  const n = value => Math.round(value * 100) / 100;
  const P = (u, v, z = 0) => [n(u - v), n((u + v) * S - z)];
  const world = ([u, v]) => [n(u + v), n((u - v) * S)];
  const plane = ([x, y]) => [(x + y / S) / 2, (x - y / S) / 2];
  const add = (a, b) => [a[0] + b[0], a[1] + b[1]];
  const textWidth = (str, cjk = 12.6, lat = 7) => {
    let w = 0;
    for (const ch of str) w += /[\u2e80-\u9fff\uff00-\uffef]/.test(ch) ? cjk : lat;
    return w;
  };

  function svg(tag, attrs, parent, text) {
    const node = document.createElementNS(NS, tag);
    for (const [key, value] of Object.entries(attrs || {})) node.setAttribute(key, value);
    if (text !== undefined) node.textContent = text;
    if (parent) parent.appendChild(node);
    return node;
  }
  function polygon(g, points, fill, stroke = '#728178', attrs = {}) {
    return svg('polygon', {
      points: points.map(p => p.map(n).join(',')).join(' '),
      fill,
      stroke,
      'stroke-width': 1.25,
      'stroke-linejoin': 'round',
      ...attrs,
    }, g);
  }
  function line(g, a, b, color, width = 1.5, attrs = {}) {
    return svg('path', {
      d: `M${a.map(n)}L${b.map(n)}`,
      fill: 'none',
      stroke: color,
      'stroke-width': width,
      'stroke-linecap': 'round',
      ...attrs,
    }, g);
  }
  function cube(g, u, v, z, w, d, h, c, attrs = {}) {
    polygon(g, [P(u, v + d, z), P(u + w, v + d, z), P(u + w, v + d, z + h), P(u, v + d, z + h)], c.front, c.ink, attrs);
    polygon(g, [P(u + w, v + d, z), P(u + w, v, z), P(u + w, v, z + h), P(u + w, v + d, z + h)], c.side, c.ink, attrs);
    polygon(g, [P(u, v, z + h), P(u + w, v, z + h), P(u + w, v + d, z + h), P(u, v + d, z + h)], c.top, c.ink, attrs);
  }
  function front(g, u, v, z, w, h, fill, stroke) {
    return polygon(g, [P(u, v, z), P(u + w, v, z), P(u + w, v, z + h), P(u, v, z + h)], fill, stroke);
  }
  function side(g, u, v, z, w, h, fill, stroke) {
    return polygon(g, [P(u, v, z), P(u, v + w, z), P(u, v + w, z + h), P(u, v, z + h)], fill, stroke);
  }
  function face(g, u, v, z) {
    const [x, y] = P(u, v, z);
    return svg('g', { transform: `matrix(1 ${n(S)} 0 1 ${x} ${y})` }, g);
  }
  function pad(g, c, u = 58, v = 52) {
    polygon(g, [P(-u, -v), P(u, -v), P(u, v), P(-u, v)].map(([x, y]) => [x + 3, y + 6]), '#edf0eb', 'none');
    polygon(g, [P(-u, -v), P(u, -v), P(u, v), P(-u, v)], '#fafbf8', '#d3ded4', { class: 'factory__pad' });
    line(g, P(-u + 8, v - 6), P(u - 8, v - 6), c.top, 3);
  }
  function dock(g, c, out = false) {
    if (out) {
      cube(g, 36, -19, 0, 16, 22, 24, c);
      side(g, 52, -16, 0, 16, 19, '#394b45', c.ink);
    } else {
      cube(g, -20, 35, 0, 24, 17, 22, c);
      front(g, -17, 52, 0, 18, 17, '#394b45', c.ink);
    }
  }

  let termBarFill = null;

  const builders = {
    chatgpt(g, c) {
      // Isometric ChatGPT Studio: clean emerald cube + front chat screen (no roof dome or logo)
      pad(g, c, 60, 52);
      cube(g, -44, -32, 0, 80, 66, 68, c);
      const scr = face(g, -38, 34.5, 60);
      svg('rect', { width: 66, height: 44, rx: 3.5, fill: '#f8fffb', stroke: c.ink, 'stroke-width': 1.3 }, scr);
      svg('rect', { x: 1, y: 1, width: 64, height: 8, rx: 2.5, fill: c.top }, scr);
      for (const [cx, col] of [[5.5, '#e08b7e'], [10.5, '#e8c478'], [15.5, '#7ec29d']]) {
        svg('circle', { cx, cy: 5, r: 1.5, fill: col }, scr);
      }
      svg('rect', { x: 24, y: 12, width: 35, height: 7, rx: 3.2, fill: c.front }, scr);
      svg('rect', { x: 28, y: 14.5, width: 25, height: 2, rx: 1, fill: '#fff' }, scr);
      svg('rect', { x: 5, y: 21.5, width: 42, height: 10, rx: 3.2, fill: '#eaf8f0', stroke: c.side, 'stroke-width': .9 }, scr);
      svg('rect', { x: 9, y: 24.2, width: 24, height: 2, rx: 1, fill: c.ink }, scr);
      svg('rect', { x: 9, y: 27.8, width: 32, height: 2, rx: 1, fill: c.side }, scr);
      svg('rect', { x: 5, y: 34.5, width: 56, height: 6.5, rx: 3.2, fill: '#fff', stroke: c.side, 'stroke-width': .9 }, scr);
      svg('circle', { cx: 56.5, cy: 37.8, r: 2.2, fill: c.ink, class: 'factory__indicator' }, scr);
      dock(g, c, true);
    },
    claude(g, c) {
      // Isometric Claude Studio: clean terracotta cube + dual-pane chat screen (no roof tier or logo)
      pad(g, c, 62, 52);
      cube(g, -46, -32, 0, 82, 66, 66, c);
      const scr = face(g, -39, 34.5, 58);
      svg('rect', { width: 68, height: 44, rx: 3.5, fill: '#fffaf4', stroke: c.ink, 'stroke-width': 1.3 }, scr);
      svg('rect', { x: 1, y: 1, width: 66, height: 8, rx: 2.5, fill: c.top }, scr);
      for (const [cx, col] of [[5.5, '#e08b7e'], [10.5, '#e8c478'], [15.5, '#7ec29d']]) {
        svg('circle', { cx, cy: 5, r: 1.5, fill: col }, scr);
      }
      svg('rect', { x: 14, y: 12, width: 22, height: 6, rx: 3, fill: c.front }, scr);
      svg('rect', { x: 4, y: 20, width: 30, height: 10.5, rx: 3, fill: '#fcefe4', stroke: c.side, 'stroke-width': .8 }, scr);
      svg('rect', { x: 7, y: 23, width: 20, height: 2, rx: 1, fill: c.ink }, scr);
      svg('rect', { x: 7, y: 26.5, width: 24, height: 2, rx: 1, fill: c.side }, scr);
      svg('rect', { x: 4, y: 33.5, width: 32, height: 6.5, rx: 3.2, fill: '#fff', stroke: c.side, 'stroke-width': .8 }, scr);
      svg('rect', { x: 39, y: 11.5, width: 25, height: 28.5, rx: 3, fill: '#fff', stroke: c.ink, 'stroke-width': 1 }, scr);
      svg('rect', { x: 42, y: 14.5, width: 14, height: 3.2, rx: 1.5, fill: c.ink }, scr);
      svg('rect', { x: 42, y: 20, width: 19, height: 2, rx: 1, fill: c.side }, scr);
      svg('rect', { x: 42, y: 24, width: 17, height: 2, rx: 1, fill: c.side }, scr);
      svg('rect', { x: 42, y: 28.5, width: 19, height: 8, rx: 2, fill: c.top }, scr);
      dock(g, c, true);
    },
    grok(g, c) {
      // Isometric Grok Studio: clean slate cube + dark-mode chat screen (no roof antenna or logo)
      pad(g, c, 60, 52);
      cube(g, -44, -32, 0, 80, 66, 66, c);
      const scr = face(g, -38, 34.5, 58);
      svg('rect', { width: 66, height: 44, rx: 3.5, fill: '#1c2430', stroke: c.ink, 'stroke-width': 1.3 }, scr);
      svg('rect', { x: 1, y: 1, width: 64, height: 8, rx: 2.5, fill: '#283344' }, scr);
      for (const [cx, col] of [[5.5, '#e08b7e'], [10.5, '#e8c478'], [15.5, '#7ec29d']]) {
        svg('circle', { cx, cy: 5, r: 1.5, fill: col }, scr);
      }
      svg('rect', { x: 24, y: 12, width: 35, height: 7, rx: 3.2, fill: '#4b5f78' }, scr);
      svg('rect', { x: 28, y: 14.5, width: 25, height: 2, rx: 1, fill: '#e8eef5' }, scr);
      svg('rect', { x: 5, y: 21.5, width: 42, height: 10, rx: 3.2, fill: '#263244', stroke: '#4b5f78', 'stroke-width': .9 }, scr);
      svg('rect', { x: 9, y: 24.2, width: 24, height: 2, rx: 1, fill: '#d6e1ee' }, scr);
      svg('rect', { x: 9, y: 27.8, width: 32, height: 2, rx: 1, fill: '#7f93ad' }, scr);
      svg('rect', { x: 5, y: 34.5, width: 56, height: 6.5, rx: 3.2, fill: '#121820', stroke: '#4b5f78', 'stroke-width': .9 }, scr);
      svg('circle', { cx: 56.5, cy: 37.8, r: 2.2, fill: '#94a8c2', class: 'factory__indicator' }, scr);
      dock(g, c, false);
    },
    luti(g, c) {
      // Isometric Mac Studio + Luti Runtime Switchboard Hub
      pad(g, c, 72, 62);
      cube(g, -48, -36, 0, 92, 72, 86, c);
      cube(g, -42, -30, 86, 80, 60, 12, c);
      // 6 color-coded tool dispatch pads on roof
      for (const [u, v, col] of [
        [-32, -18, '#95b06d'],
        [-8, -18, '#d98c78'],
        [16, -18, '#6e98cc'],
        [-32, 2, '#c59d4e'],
        [-8, 2, '#56aab4'],
        [16, 2, '#c985ab'],
      ]) {
        polygon(g, [P(u, v, 98.5), P(u + 16, v, 98.5), P(u + 16, v + 13, 98.5), P(u, v + 13, 98.5)], col, c.ink);
      }
      // Luti Runtime Control Screen flush on upper front-left wall (v = 36.5, z = 34..80)
      const scr = face(g, -39, 36.5, 80);
      svg('rect', { width: 72, height: 44, rx: 4, fill: '#fcf9ff', stroke: c.ink, 'stroke-width': 1.4 }, scr);
      svg('rect', { x: 1, y: 1, width: 70, height: 8.5, rx: 3, fill: c.top }, scr);
      for (const [cx, col] of [[6, '#e08b7e'], [11.5, '#e8c478'], [17, '#7ec29d']]) {
        svg('circle', { cx, cy: 5.2, r: 1.6, fill: col }, scr);
      }
      svg('rect', { x: 6, y: 13, width: 16, height: 16, rx: 4, fill: c.ink }, scr);
      svg('path', { d: 'M11 17v8h6', fill: 'none', stroke: '#fff', 'stroke-width': 2.4, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }, scr);
      svg('rect', { x: 26, y: 14, width: 38, height: 5.5, rx: 2.5, fill: c.top }, scr);
      svg('rect', { x: 26, y: 22, width: 28, height: 5, rx: 2.5, fill: '#dcefe3' }, scr);
      for (const [idx, col] of ['#779250', '#c0634b', '#507ebc', '#ad8434', '#388d99', '#a45a82'].entries()) {
        svg('rect', { x: 5.5 + idx * 10.4, y: 33, width: 8.6, height: 6, rx: 2, fill: col }, scr);
      }
      // Inbound Tunnel gate & Outbound Tool gate
      cube(g, -22, 36, 0, 28, 18, 26, c);
      front(g, -17, 54, 0, 18, 20, '#604579', c.ink);
      cube(g, 44, -25, 0, 16, 34, 30, c);
      side(g, 60, -19, 0, 22, 23, '#604579', c.ink);
    },
    memory(g, c) {
      // Isometric Project Memory Archive: 3 tiered 3D Knowledge Cards & Synapse Graph
      pad(g, c, 64, 54);
      cube(g, -44, -32, 0, 86, 64, 14, c);
      for (const [v, z] of [[-24, 96], [-4, 86]]) {
        cube(g, -38, v, 14, 76, 9, z - 14, c);
        const card = face(g, -33, v + 9.5, z - 6);
        svg('rect', { width: 64, height: 34, rx: 3, fill: '#fafdf5', stroke: c.ink, 'stroke-width': 1.1 }, card);
        svg('rect', { x: 4, y: 4, width: 20, height: 5, rx: 2, fill: c.side }, card);
        svg('rect', { x: 4, y: 13, width: 48, height: 3, rx: 1.5, fill: c.top }, card);
        svg('rect', { x: 4, y: 20, width: 38, height: 3, rx: 1.5, fill: c.top }, card);
      }
      const frontSlab = svg('g', { class: 'st-mem__blade' }, g);
      cube(frontSlab, -38, 16, 14, 76, 10, 62, c);
      const activeCard = face(frontSlab, -33, 26.5, 70);
      svg('rect', { width: 64, height: 42, rx: 3.5, fill: '#fcfff6', stroke: c.ink, 'stroke-width': 1.3 }, activeCard);
      svg('rect', { x: 1, y: 1, width: 62, height: 8.5, rx: 2.5, fill: c.top }, activeCard);
      svg('circle', { cx: 6.5, cy: 5.2, r: 2.2, fill: c.ink }, activeCard);
      svg('rect', { x: 12, y: 3.8, width: 28, height: 2.8, rx: 1.4, fill: c.ink }, activeCard);
      const decisionRow = svg('g', { class: 'st-mem__new' }, activeCard);
      svg('rect', { x: 4, y: 12.5, width: 56, height: 13, rx: 2.5, fill: '#dcf0b4', stroke: c.ink, 'stroke-width': .9 }, decisionRow);
      svg('rect', { x: 7, y: 15.5, width: 16, height: 6.5, rx: 2, fill: c.ink }, decisionRow);
      svg('rect', { x: 26, y: 16.5, width: 30, height: 2.3, rx: 1, fill: c.ink }, decisionRow);
      svg('rect', { x: 26, y: 20.5, width: 22, height: 2, rx: 1, fill: c.side }, decisionRow);
      line(activeCard, [12, 34], [30, 31], c.ink, 1.4);
      line(activeCard, [30, 31], [48, 35], c.ink, 1.4);
      for (const [nx, ny] of [[12, 34], [30, 31], [48, 35]]) {
        svg('circle', { cx: nx, cy: ny, r: 3, fill: '#fff', stroke: c.ink, 'stroke-width': 1.4 }, activeCard);
      }
      dock(g, c, false);
    },
    git(g, c) {
      // Isometric Project & Git Observatory: Stack Detector + Branch & Commit Graph
      pad(g, c, 62, 54);
      cube(g, -44, -32, 0, 86, 64, 70, c);
      cube(g, -34, -22, 70, 66, 44, 10, c);
      const scr = face(g, -38, 33, 64);
      svg('rect', { width: 70, height: 42, rx: 3.5, fill: '#fffaf8', stroke: c.ink, 'stroke-width': 1.3 }, scr);
      svg('rect', { x: 1, y: 1, width: 68, height: 8, rx: 2.5, fill: c.top }, scr);
      for (const [cx, col] of [[5.5, '#e08b7e'], [10.5, '#e8c478'], [15.5, '#7ec29d']]) {
        svg('circle', { cx, cy: 5, r: 1.5, fill: col }, scr);
      }
      svg('rect', { x: 22, y: 3.6, width: 26, height: 2.6, rx: 1.3, fill: c.ink }, scr);
      // Main branch & feature branch graph
      line(scr, [12, 16], [56, 16], c.side, 2.2);
      const branch = svg('g', { class: 'st-git__branch' }, scr);
      svg('path', { d: 'M20 16C26 16 27 27 33 27H47C52 27 53 16 56 16', fill: 'none', stroke: c.ink, 'stroke-width': 2.2, 'stroke-linecap': 'round' }, branch);
      for (const [cx, cy] of [[14, 16], [26, 16], [56, 16]]) {
        svg('circle', { cx, cy, r: 3, fill: '#fff', stroke: c.side, 'stroke-width': 1.8 }, scr);
      }
      for (const [cx, cy] of [[34, 27], [46, 27]]) {
        svg('circle', { cx, cy, r: 3.2, fill: c.top, stroke: c.ink, 'stroke-width': 1.8 }, branch);
      }
      svg('rect', { x: 8, y: 33, width: 24, height: 5, rx: 2, fill: c.top }, scr);
      svg('rect', { x: 35, y: 33, width: 26, height: 5, rx: 2, fill: '#dcf0b4' }, branch);
      dock(g, c, false);
    },
    code(g, c) {
      // Isometric 3D Code Editor Windows + Live Git Diff + Folder Tab
      pad(g, c, 62, 54);
      for (const [idx, [v, z]] of [[-26, 100], [-4, 89], [18, 78]].entries()) {
        const grp = idx === 2 ? svg('g', { class: 'st-code__sheet' }, g) : g;
        cube(grp, -40, v, 0, 81, 7, z, c);
        const win = face(grp, -34, v + 7.5, z - 6);
        svg('rect', { width: 64, height: 38, rx: 3, fill: '#f8fbff', stroke: c.ink, 'stroke-width': 1.2 }, win);
        svg('rect', { x: 1, y: 1, width: 62, height: 6.5, rx: 2, fill: c.top }, win);
        for (const [cx, col] of [[5, '#e08b7e'], [9.5, '#e8c478'], [14, '#7ec29d']]) {
          svg('circle', { cx, cy: 4.2, r: 1.3, fill: col }, win);
        }
        if (idx === 2) {
          svg('rect', { x: 5, y: 10.5, width: 32, height: 2.4, rx: 1, fill: c.side }, win);
          svg('rect', { x: 4, y: 15, width: 54, height: 5, rx: 1.5, fill: '#fde2df' }, win);
          svg('rect', { x: 7, y: 16.5, width: 30, height: 2, rx: 1, fill: '#c95c54' }, win);
          const addDiff = svg('g', { class: 'st-code__add' }, win);
          svg('rect', { x: 4, y: 21.5, width: 54, height: 13, rx: 2, fill: '#d4f5dd', stroke: '#3a8c55', 'stroke-width': .8 }, addDiff);
          svg('rect', { x: 7, y: 24, width: 42, height: 2.3, rx: 1, fill: '#287a43' }, addDiff);
          svg('rect', { x: 7, y: 28.5, width: 34, height: 2.3, rx: 1, fill: '#287a43' }, addDiff);
        } else {
          for (let k = 0; k < 3; k++) {
            svg('rect', { x: 6, y: 12 + k * 7, width: 42 - k * 6, height: 2.6, rx: 1.2, fill: c.side, opacity: .7 }, win);
          }
        }
      }
      const folder = [P(-45, 43, 0), P(47, 43, 0), P(47, 43, 56), P(1, 43, 56), P(-12, 43, 72), P(-45, 43, 72)];
      polygon(g, folder, c.front, c.ink);
      const mark = face(g, 2, 44, 36);
      svg('path', { d: 'm-10-9-11 9 11 9m18-18 11 9-11 9m-6-21-7 24', fill: 'none', stroke: '#f9fcff', 'stroke-width': 2.8, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }, mark);
      dock(g, c, false);
    },
    terminal(g, c) {
      // Isometric Dark Terminal Monitor & CLI Runner Deck
      pad(g, c, 64, 54);
      cube(g, -46, -32, 0, 90, 66, 78, c);
      // Dark terminal screen flush on front-left wall (v = 34.5, z = 24..72)
      const scr = face(g, -39, 34.5, 72);
      svg('rect', { width: 74, height: 46, rx: 4, fill: '#1b2019', stroke: c.ink, 'stroke-width': 1.4 }, scr);
      svg('rect', { x: 1, y: 1, width: 72, height: 8.5, rx: 3, fill: '#2e352b' }, scr);
      for (const [cx, col] of [[6, '#e08b7e'], [11.5, '#e8c478'], [17, '#7ec29d']]) {
        svg('circle', { cx, cy: 5.2, r: 1.6, fill: col }, scr);
      }
      svg('rect', { x: 24, y: 4, width: 28, height: 2.3, rx: 1.1, fill: '#99a892' }, scr);
      svg('path', { d: 'm6 14 5 3.5-5 3.5m7 1h9', fill: 'none', stroke: '#ffefb1', 'stroke-width': 2.2, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }, scr);
      svg('rect', { x: 26, y: 16, width: 38, height: 2.6, rx: 1.2, fill: '#e6ede2' }, scr);
      const passRow = svg('g', { class: 'st-term__pass' }, scr);
      svg('rect', { x: 6, y: 24.5, width: 18, height: 7.5, rx: 2.5, fill: '#2ea058' }, passRow);
      svg('path', { d: 'M10.5 28.2 13.5 30.8 19.5 26', fill: 'none', stroke: '#fff', 'stroke-width': 1.8, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }, passRow);
      svg('rect', { x: 28, y: 27, width: 38, height: 2.8, rx: 1.4, fill: '#7ce09b' }, passRow);
      svg('rect', { x: 6, y: 36.5, width: 62, height: 4, rx: 2, fill: '#2f382d' }, scr);
      termBarFill = svg('rect', { x: 6, y: 36.5, width: 56, height: 4, rx: 2, fill: '#57d482' }, scr);
      for (let v = -22; v < 22; v += 9) side(g, 44.5, v, 16, 4, 42, c.ink, 'none');
      dock(g, c, false);
    },
    browser(g, c) {
      // Isometric Widescreen Browser Display + Keyboard Deck + Viewfinder & Shutter Flash
      pad(g, c, 73, 54);
      cube(g, -55, 4, 13, 110, 10, 97, c);
      const display = face(g, -48, 15, 102);
      svg('rect', { width: 96, height: 80, rx: 3, fill: '#f5fdfb' }, display);
      svg('path', { d: 'M0 15h96', stroke: c.side, 'stroke-width': 1 }, display);
      for (const [x, color] of [[7, '#d89487'], [15, '#e7c583'], [23, '#85bca7']]) {
        svg('circle', { cx: x, cy: 7.5, r: 2.3, fill: color }, display);
      }
      svg('rect', { x: 31, y: 3.5, width: 56, height: 8, rx: 4, fill: '#fff', stroke: c.side, 'stroke-width': .8 }, display);
      svg('rect', { x: 37, y: 6.5, width: 32, height: 2, rx: 1, fill: c.ink, opacity: .65 }, display);
      svg('rect', { x: 6, y: 23, width: 31, height: 47, rx: 2, fill: c.top }, display);
      svg('rect', { x: 45, y: 23, width: 44, height: 22, rx: 3, fill: c.front }, display);
      svg('path', { d: 'M50 39 58 31 67 35 77 27 84 30', fill: 'none', stroke: '#fff', 'stroke-width': 2.2, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }, display);
      for (let i = 0; i < 3; i++) {
        svg('rect', { x: 45, y: 52 + i * 8, width: 40 - i * 7, height: 3, rx: 1, fill: c.side, opacity: .65 }, display);
      }
      const finder = svg('g', { class: 'st-browser__finder' }, display);
      svg('path', {
        d: 'M4 26v-7h7M92 26v-7h-7M4 67v7h7M92 67v7h-7',
        fill: 'none',
        stroke: '#1b646e',
        'stroke-width': 2.5,
        'stroke-linecap': 'round',
      }, finder);
      svg('circle', { cx: 48, cy: 46, r: 7, fill: 'none', stroke: '#1b646e', 'stroke-width': 1.6, 'stroke-dasharray': '3 2' }, finder);
      svg('rect', { width: 96, height: 80, rx: 3, fill: '#ffffff', class: 'st-browser__flash' }, display);
      cube(g, -38, 20, 0, 77, 27, 6, c);
      for (let u = -30; u < 31; u += 12) {
        for (let v = 24; v < 42; v += 8) {
          polygon(g, [P(u, v, 7), P(u + 8, v, 7), P(u + 8, v + 5, 7), P(u, v + 5, 7)], '#f0fcfa', c.side);
        }
      }
      dock(g, c, false);
    },
    artifacts(g, c) {
      // Isometric Artifact Exchange Depot: 3D Resource Crates + Preview/PDF Transfer Screen
      pad(g, c, 62, 54);
      cube(g, -44, -32, 0, 86, 64, 66, c);
      const crate = svg('g', { class: 'st-art__crate' }, g);
      cube(crate, -28, -18, 66, 54, 36, 18, c);
      polygon(crate, [P(-6, -18, 84.3), P(4, -18, 84.3), P(4, 18, 84.3), P(-6, 18, 84.3)], '#fff5fa', c.ink);
      const scr = face(g, -38, 33, 60);
      svg('rect', { width: 70, height: 40, rx: 3.5, fill: '#fff9fc', stroke: c.ink, 'stroke-width': 1.3 }, scr);
      svg('rect', { x: 1, y: 1, width: 68, height: 7.5, rx: 2.5, fill: c.top }, scr);
      for (const [cx, col] of [[5.5, '#e08b7e'], [10.5, '#e8c478'], [15.5, '#7ec29d']]) {
        svg('circle', { cx, cy: 4.8, r: 1.4, fill: col }, scr);
      }
      svg('rect', { x: 5, y: 12, width: 28, height: 22, rx: 2.5, fill: c.top, stroke: c.side, 'stroke-width': .9 }, scr);
      svg('circle', { cx: 13, cy: 18, r: 2.4, fill: c.ink }, scr);
      svg('path', { d: 'm8 30 7-7 5 4 5-5 5 8Z', fill: c.front }, scr);
      const badge = svg('g', { class: 'st-art__badge' }, scr);
      svg('rect', { x: 38, y: 12, width: 26, height: 10, rx: 2.5, fill: '#dcf0b4', stroke: c.ink, 'stroke-width': .9 }, badge);
      svg('rect', { x: 42, y: 15.8, width: 18, height: 2.4, rx: 1.2, fill: c.ink }, badge);
      svg('rect', { x: 38, y: 25, width: 26, height: 9, rx: 2.5, fill: '#fff', stroke: c.side, 'stroke-width': .9 }, scr);
      svg('rect', { x: 42, y: 28.5, width: 16, height: 2.2, rx: 1.1, fill: c.side }, scr);
      dock(g, c, false);
    },
  };

  const ports = {
    chatgpt: { out: P(52, -8) },
    claude: { out: P(52, -8) },
    grok: { out: P(-8, 52) },
    luti: { in: P(-8, 54), out: P(60, -8) },
    memory: { in: P(-8, 52) },
    git: { in: P(-8, 52) },
    code: { in: P(-8, 52) },
    terminal: { in: P(-8, 52) },
    browser: { in: P(-8, 52) },
    artifacts: { in: P(-8, 52) },
  };

  for (const node of nodes) {
    const name = node.dataset.node;
    const c = palette[name];
    node.style.setProperty('--tone', c.ink);
    node.style.setProperty('--wash', c.wash);
    builders[name](node.querySelector('.factory__art'), c);
    node.querySelector('.factory__label').setAttribute('y', name === 'luti' ? 91 : 83);
  }

  let groundRoutes = {};
  let spurRoutes = [];
  let paths = {};
  let inbound = {};
  let positions = {};
  let scenarioIndex = 0;
  let selectedClient = scenarios[0].client;
  let selectedTool = scenarios[0].tool;
  let elapsed = 0;
  let activeLine = null;
  let frameId = null;
  let lastFrame = 0;
  let lastPaint = 0;
  let visible = true;
  let lastStage = -1;
  let toastKey = '';

  const DURATION = 11600;
  const ends = [.16, .32, .42, .54, .72, .85, 1];

  // Clean parcel moving along the conveyor belt (no trailing bubble)
  const primaryPacket = svg('g', { class: 'factory__parcel' }, packetLayer);
  const primaryBox = svg('use', { href: '#factoryParcel', x: -22, y: -36, width: 44, height: 48 }, primaryPacket);

  // Gentle toast bubble that pops above a building and fades out
  const toastGroup = svg('g', { class: 'factory__overlay', filter: 'url(#factoryShadow)' }, overlayLayer);
  const toastInner = svg('g', {}, toastGroup);

  function toastAnchor(target) {
    const [x, y] = positions[target];
    const offsets = {
      chatgpt: [0, -106],
      claude: [0, -106],
      grok: [0, -106],
      luti: [0, -142],
      memory: [4, -144],
      git: [2, -124],
      code: [6, -142],
      terminal: [0, -124],
      browser: [-2, -134],
      artifacts: [0, -128],
    };
    const [dx, dy] = offsets[target] || [0, -120];
    if (compact.matches) {
      const cx = target === 'chatgpt' || target === 'git' || target === 'terminal' ? 24 : target === 'grok' || target === 'memory' || target === 'code' || target === 'browser' ? -24 : dx;
      return [x + cx, y + dy];
    }
    return [x + dx, y + dy];
  }

  function buildToast(target, text, color, isSuccess = false) {
    toastInner.replaceChildren();
    if (!target || !text) return;
    const [tx, ty] = toastAnchor(target);
    toastGroup.setAttribute('transform', `translate(${n(tx)} ${n(ty)})`);
    const w = Math.max(156, textWidth(text) + 38);
    const h = 30;
    svg('path', {
      d: `M${-w / 2 + 15} ${-h}H${w / 2 - 15}A15 15 0 0 1 ${w / 2} ${-h + 15}V-15A15 15 0 0 1 ${w / 2 - 15} 0H5L0 5L-5 0H${-w / 2 + 15}A15 15 0 0 1 ${-w / 2} -15V${-h + 15}A15 15 0 0 1 ${-w / 2 + 15} ${-h}Z`,
      fill: '#ffffff',
      stroke: color,
      'stroke-width': 1.4,
    }, toastInner);
    svg('circle', {
      cx: -w / 2 + 14,
      cy: -h / 2,
      r: 3.8,
      fill: isSuccess ? '#2ea058' : color,
    }, toastInner);
    svg('text', {
      x: 5,
      y: -h / 2 + 4,
      'text-anchor': 'middle',
      fill: '#263530',
      style: 'font:600 11.5px var(--font)',
    }, toastInner, text);
  }

  function path(points) {
    let length = 0;
    const segments = points.slice(1).map((b, i) => {
      const a = points[i];
      const size = Math.hypot(b[0] - a[0], b[1] - a[1]);
      const part = { a, b, start: length, size };
      length += size;
      return part;
    }).filter(s => s.size > 0);
    return { segments, length };
  }
  function pointAt(route, f) {
    const distance = Math.max(0, Math.min(1, f)) * route.length;
    const s = route.segments.find(seg => distance <= seg.start + seg.size) || route.segments.at(-1);
    const tNorm = (distance - s.start) / s.size;
    return [s.a[0] + (s.b[0] - s.a[0]) * tNorm, s.a[1] + (s.b[1] - s.a[1]) * tNorm];
  }
  const pathData = points => points.map((p, i) => (i ? 'L' : 'M') + p.map(n).join(' ')).join('');
  function isoRoute(a, b, first = 'u') {
    const u = plane(a);
    const v = plane(b);
    return [u, first === 'u' ? [v[0], u[1]] : [u[0], v[1]], v];
  }
  function position(name, gate, port) {
    positions[name] = [gate[0] - port[0], gate[1] - port[1]];
  }

  function layout() {
    positions = {};
    if (!compact.matches) {
      const origin = [450, 366];
      const project = p => add(world(p), origin);
      const clientLanes = {
        chatgpt: [[-245, 0], [0, 0]],
        claude: [[-65, -205], [0, -205], [0, 0]],
        grok: [[160, -145], [160, -205], [0, -205], [0, 0]],
        tunnel: [[0, 0], [0, 190]],
      };
      // Open-ended side branches on the left road indicating more AI clients/tools can connect
      const clientSpurs = [
        [[-125, 0], [-125, 130], [-195, 130]],
        [[55, -205], [55, -295]],
      ];
      groundRoutes = Object.fromEntries(Object.entries(clientLanes).map(([name, ps]) => [name, ps.map(p => plane(project(p)))]));
      spurRoutes = clientSpurs.map(ps => ps.map(p => plane(project(p))));
      for (const name of clients) position(name, project(clientLanes[name][0]), ports[name].out);
      position('luti', project(clientLanes.tunnel.at(-1)), ports.luti.in);
      const outlet = add(positions.luti, ports.luti.out);
      const local = {
        memory: [[0, 0], [5, 0], [5, 255]],
        git: [[0, 0], [215, 0], [215, 80]],
        code: [[0, 0], [125, 0], [125, 280], [265, 280], [265, 370]],
        artifacts: [[0, 0], [455, 0], [455, 55]],
        terminal: [[0, 0], [70, 0], [70, -205], [155, -205], [155, -165]],
        browser: [[0, 0], [260, 0], [260, -235], [385, -235], [385, -195]],
      };
      for (const [name, ps] of Object.entries(local)) {
        groundRoutes[name] = ps.map(p => plane(add(world(p), outlet)));
        position(name, world(groundRoutes[name].at(-1)), ports[name].in);
      }
      scene.setAttribute('viewBox', '0 -84 1600 772');
      setBoundary(602, -62, 994, 742, 634, -70, 72, -70);
      tunnelNode.setAttribute('transform', 'translate(492 260)');
    } else {
      positions = {
        chatgpt: [140, 205],
        claude: [437, 173],
        grok: [745, 215],
        luti: [410, 514],
        memory: [705, 670],
        git: [204, 790],
        code: [715, 920],
        terminal: [210, 1045],
        browser: [720, 1155],
        artifacts: [440, 1235],
      };
      const gate = name => add(positions[name], ports[name].out);
      const junction = [232, 405];
      const entry = add(positions.luti, ports.luti.in);
      const exit = add(positions.luti, ports.luti.out);
      groundRoutes = {
        chatgpt: isoRoute(gate('chatgpt'), junction),
        claude: isoRoute(gate('claude'), junction, 'v'),
        grok: isoRoute(gate('grok'), junction, 'v'),
        tunnel: isoRoute(junction, entry),
      };
      spurRoutes = [
        isoRoute([120, 355], junction),
        isoRoute([580, 345], [450, 345]),
      ];
      const trunk = isoRoute(exit, [446, 920]);
      for (const name of tools) {
        const target = add(positions[name], ports[name].in);
        const approach = [target[0] - 72, target[1] + 72 * S];
        groundRoutes[name] = [...trunk, ...isoRoute(world(trunk.at(-1)), approach).slice(1), plane(target)];
      }
      scene.setAttribute('viewBox', '0 0 900 1360');
      setBoundary(55, 367, 789, 965, 84, 354, 50, 43);
      tunnelNode.setAttribute('transform', 'translate(141 474)');
    }
    for (const node of nodes) node.setAttribute('transform', `translate(${positions[node.dataset.node].map(n).join(' ')})`);
    nodes.slice().sort((a, b) => positions[a.dataset.node][1] - positions[b.dataset.node][1]).forEach(node => stationLayer.appendChild(node));
    paths = Object.fromEntries(Object.entries(groundRoutes).map(([name, ps]) => [name, path(ps.map(world))]));
    inbound = Object.fromEntries(clients.map(name => [name, path([...groundRoutes[name], ...groundRoutes.tunnel.slice(1)].map(world))]));
    drawLanes();
    lastStage = -1;
    toastKey = '';
    render();
  }

  function setBoundary(x, y, width, height, wx, wy, rx, ry) {
    const boundary = document.getElementById('factoryBoundary');
    Object.entries({ x, y, width, height }).forEach(([key, value]) => boundary.setAttribute(key, value));
    for (const [id, px, py] of [['factoryWorkspace', wx, wy], ['factoryRemote', rx, ry]]) {
      const el = document.getElementById(id);
      el.setAttribute('x', px);
      el.setAttribute('y', py);
    }
  }

  function drawLanes() {
    laneLayer.replaceChildren();
    const ground = svg('g', { transform: `matrix(1 ${S} 1 ${-S} 0 0)`, fill: 'none', 'stroke-linejoin': 'miter', 'stroke-miterlimit': 2 }, laneLayer);
    const all = [...Object.values(groundRoutes), ...spurRoutes];
    for (const ps of all) svg('path', { d: pathData(ps), stroke: '#bdcbbd', 'stroke-width': 25 }, ground);
    for (const ps of all) svg('path', { d: pathData(ps), stroke: '#f0f4eb', 'stroke-width': 22 }, ground);
    svg('path', { d: pathData(groundRoutes.tunnel), stroke: '#ece4f5', 'stroke-width': 22 }, ground);
    const segments = new Map();
    all.forEach(ps => ps.slice(1).forEach((b, i) => {
      const a = ps[i];
      segments.set([a.map(n).join(','), b.map(n).join(',')].sort().join(':'), { a, b });
    }));
    let ribs = '';
    for (const { a, b } of segments.values()) {
      const length = Math.hypot(b[0] - a[0], b[1] - a[1]);
      if (length < 30) continue;
      const du = (b[0] - a[0]) / length;
      const dv = (b[1] - a[1]) / length;
      for (let d = 22; d < length - 22; d += 17) {
        const u = a[0] + du * d;
        const v = a[1] + dv * d;
        ribs += `M${n(u - dv * 10)} ${n(v + du * 10)}L${n(u + dv * 10)} ${n(v - du * 10)}`;
      }
    }
    svg('path', { d: ribs, stroke: '#d0dccc', 'stroke-width': 1 }, ground);
    activeLine = svg('path', { 'stroke-width': 3, 'stroke-dasharray': '6 10', opacity: .72 }, ground);
  }

  function phaseAt(time) {
    const fraction = (time % DURATION) / DURATION;
    const stage = ends.findIndex(end => fraction < end);
    const start = stage === 0 ? 0 : ends[stage - 1];
    return { stage, fraction: (fraction - start) / (ends[stage] - start) };
  }

  function render() {
    const { stage, fraction } = phaseAt(elapsed);
    const clientColor = palette[selectedClient].ink;
    const toolColor = palette[selectedTool].ink;

    if (stage !== lastStage) {
      lastStage = stage;
      const clientLeg = [...groundRoutes[selectedClient], ...groundRoutes.tunnel.slice(1)];
      const toolLeg = groundRoutes[selectedTool];
      activeLine.setAttribute('d', `${pathData(clientLeg)} ${pathData(toolLeg)}`);
      activeLine.setAttribute('stroke', stage >= 4 ? toolColor : clientColor);
      factory.dataset.phase = String(stage);
    }

    if (stage === 1 && fraction > 0.35) tunnelNode.dataset.flow = 'request';
    else if (stage === 5 && fraction > 0.3) tunnelNode.dataset.flow = 'return';
    else delete tunnelNode.dataset.flow;

    const moving = stage === 1 || stage === 3 || stage === 5;
    primaryPacket.style.display = moving ? '' : 'none';
    primaryBox.style.color = stage >= 5 ? toolColor : clientColor;
    if (moving) {
      let p;
      if (stage === 1) {
        p = pointAt(inbound[selectedClient], fraction);
      } else if (stage === 3) {
        p = pointAt(paths[selectedTool], fraction);
      } else {
        p = fraction < 0.48
          ? pointAt(paths[selectedTool], 1 - fraction / 0.48)
          : pointAt(inbound[selectedClient], 1 - (fraction - 0.48) / 0.52);
      }
      primaryPacket.setAttribute('transform', `translate(${p.map(n).join(' ')})`);
      primaryPacket.style.opacity = String(n(Math.min(1, fraction * 12, (1 - fraction) * 12)));
    }

    if (termBarFill) {
      const w = selectedTool === 'terminal' && stage === 4 ? Math.round(12 + fraction * 50) : 56;
      termBarFill.setAttribute('width', String(w));
    }

    const working = new Set([
      stage <= 1 || stage === 6 ? selectedClient : null,
      stage === 2 || (stage === 5 && fraction > 0.38 && fraction < 0.6) ? 'luti' : null,
      stage === 3 || stage === 4 || (stage === 5 && fraction < 0.35) ? selectedTool : null,
    ]);
    for (const node of nodes) {
      const name = node.dataset.node;
      node.classList.toggle('is-working', working.has(name));
      node.classList.toggle('is-acting', (stage === 4 && name === selectedTool) || (stage === 2 && name === 'luti'));
      node.classList.toggle('is-flashing', stage === 4 && name === 'browser' && selectedTool === 'browser' && fraction > 0.24 && fraction < 0.52);
    }

    // Gentle building toast bubble: pops above the active building, floats up slightly, and fades out
    let target = '';
    let text = '';
    let color = clientColor;
    let isSuccess = false;
    if (stage === 0) {
      target = selectedClient;
      text = t(`factory.ask.${selectedTool}`);
      color = clientColor;
    } else if (stage === 2) {
      target = 'luti';
      text = `${t('factory.act.luti')} → ${toolMeta[selectedTool].short}`;
      color = palette.luti.ink;
    } else if (stage === 4) {
      target = selectedTool;
      text = t(`factory.act.${selectedTool}`);
      color = toolColor;
    } else if (stage === 6) {
      target = selectedClient;
      text = t(`factory.reply.${selectedTool}`);
      color = toolColor;
      isSuccess = true;
    }

    const nextKey = `${target}:${text}`;
    if (nextKey !== toastKey) {
      toastKey = nextKey;
      buildToast(target, text, color, isSuccess);
    }

    if (target) {
      const fadeIn = Math.min(1, fraction / 0.22);
      const fadeOut = Math.min(1, Math.max(0, (0.94 - fraction) / 0.32));
      const alpha = n(fadeIn * fadeOut);
      const floatY = n(5 - fraction * 12);
      toastGroup.style.opacity = String(alpha);
      toastInner.setAttribute('transform', `translate(0 ${floatY})`);
    } else {
      toastGroup.style.opacity = '0';
    }
  }

  function updateLabels() {
    for (const node of nodes) {
      const name = node.dataset.node;
      node.setAttribute('aria-label', node.querySelector('.factory__label').textContent.trim());
      node.setAttribute('aria-pressed', String(name === selectedClient || name === selectedTool));
    }
    factory.dataset.client = selectedClient;
    factory.dataset.task = selectedTool;
  }

  function choose(node) {
    const name = node.dataset.node;
    if (clients.includes(name)) {
      selectedClient = name;
    } else if (tools.includes(name)) {
      selectedTool = name;
    } else if (name === 'luti') {
      scenarioIndex = (scenarioIndex + 1) % scenarios.length;
      selectedClient = scenarios[scenarioIndex].client;
      selectedTool = scenarios[scenarioIndex].tool;
    }
    elapsed = 0;
    lastStage = -1;
    toastKey = '';
    updateLabels();
    render();
  }

  function frame(now) {
    if (!lastFrame) lastFrame = now;
    const dt = Math.min(now - lastFrame, 100);
    const prevCycle = Math.floor(elapsed / DURATION);
    elapsed += dt;
    const nextCycle = Math.floor(elapsed / DURATION);
    if (nextCycle > prevCycle) {
      scenarioIndex = (scenarioIndex + 1) % scenarios.length;
      selectedClient = scenarios[scenarioIndex].client;
      selectedTool = scenarios[scenarioIndex].tool;
      lastStage = -1;
      toastKey = '';
      updateLabels();
    }
    lastFrame = now;
    if (now - lastPaint >= 32) {
      render();
      lastPaint = now;
    }
    frameId = requestAnimationFrame(frame);
  }

  function syncPlayback() {
    if (frameId !== null) cancelAnimationFrame(frameId);
    frameId = null;
    lastFrame = 0;
    const playing = !reduced.matches && visible && !document.hidden;
    if (playing) frameId = requestAnimationFrame(frame);
    else if (reduced.matches) {
      elapsed = Math.floor(DURATION * 0.9);
      render();
    }
    factory.dataset.motion = playing ? 'playing' : 'paused';
  }

  nodes.forEach(node => {
    node.addEventListener('click', () => choose(node));
    node.addEventListener('keydown', event => {
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault();
        choose(node);
      }
    });
  });
  compact.addEventListener('change', layout);
  reduced.addEventListener('change', syncPlayback);
  document.addEventListener('visibilitychange', syncPlayback);
  new IntersectionObserver(([entry]) => {
    visible = entry.isIntersecting;
    syncPlayback();
  }).observe(factory);
  window.lutiI18n.on(() => {
    toastKey = '';
    updateLabels();
    render();
  });
  layout();
  updateLabels();
  syncPlayback();
})();
