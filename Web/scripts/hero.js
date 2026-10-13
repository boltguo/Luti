/* Illustrative remote MCP flow. No real tools are called.
 * Buildings are raster assets; the topology and parcel journeys are exact
 * code-driven paths. Every tool request must pass through Tunnel and Luti.
 * All projected coordinates use the same 1500 × 950 diagram space.
 */
(() => {
  const factory = document.getElementById('factory');
  if (!factory) return;
  const scene = document.getElementById('factoryScene');
  const canvas = document.getElementById('factoryRoutes');
  const ctx = canvas.getContext('2d');
  const parcelLayer = document.getElementById('factoryParcels');
  const nodes = [...scene.querySelectorAll('[data-node]')];
  const i18n = window.lutiI18n;
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const DURATION = 18000;
  const WIDTH = 1500, HEIGHT = 950;
  const clients = ['chatgpt', 'claude', 'grok'];
  const toolNames = ['code', 'terminal', 'browser', 'memory'];
  // Lay out orthogonal lanes on the ground plane, then project the whole
  // network. Widths, square corners and rollers share the buildings' ±30° axes.
  const ISO_SLOPE = Math.tan(Math.PI / 6);
  const ORIGIN = [450, 570];
  const LANE_WIDTH = 24;
  const BORDER_WIDTH = 1.5;
  const groundRoutes = {
    chatgpt: [[-225, 0], [0, 0]],
    claude: [[-40, -260], [0, -260], [0, 0]],
    grok: [[170, -225], [170, -340], [0, -340], [0, -260], [0, 0]],
    tunnel: [[0, 0], [0, 240]],
  };
  const project = ([u, v]) => [ORIGIN[0] + u + v, ORIGIN[1] + (u - v) * ISO_SLOPE];
  const unproject = ([x, y]) => [(x - ORIGIN[0] + (y - ORIGIN[1]) / ISO_SLOPE) / 2, (x - ORIGIN[0] - (y - ORIGIN[1]) / ISO_SLOPE) / 2];
  // Anchor factories to measured door positions in their 512px sprites.
  // Routes and buildings must share these anchors instead of separate CSS
  // percentages that drift when the diagram changes height.
  function placeStation(name, gate, port, size = 180, labelTop = 140) {
    const node = nodes.find(n => (n.dataset.client || n.dataset.node) === name);
    const left = gate[0] - port[0] / 512 * size;
    const top = gate[1] - port[1] / 512 * size;
    node.style.setProperty('--x', `${left / WIDTH * 100}%`);
    node.style.setProperty('--y', `${top / HEIGHT * 100}%`);
    node.style.setProperty('--w', `${size / WIDTH * 100}%`);
    node.style.setProperty('--label-top', `${labelTop / 512 * 100}%`);
    return [left, top];
  }
  const hubPosition = placeStation('luti', project(groundRoutes.tunnel.at(-1)), [199, 443], 250, 20);
  const hubOutlet = unproject([hubPosition[0] + 389 / 512 * 250, hubPosition[1] + 405 / 512 * 250]);
  const localRoutes = {
    memory: [[0, 0], [120, 0], [120, 300]],
    code: [[0, 0], [120, 0], [300, 0], [300, 300]],
    browser: [[0, 0], [120, 0], [300, 0], [500, 0], [500, 90]],
    terminal: [[0, 0], [120, 0], [120, -310], [365, -310], [365, -135]],
  };
  for (const [name, points] of Object.entries(localRoutes)) groundRoutes[name] = points.map(([u, v]) => [u + hubOutlet[0], v + hubOutlet[1]]);
  placeStation('chatgpt', project(groundRoutes.chatgpt[0]), [340, 409]);
  placeStation('claude', project(groundRoutes.claude[0]), [340, 409]);
  placeStation('grok', project(groundRoutes.grok[0]), [188, 434]);
  const toolPorts = { memory: [188, 400], code: [199, 439], browser: [208, 391], terminal: [177, 396] };
  const labelTops = { memory: 26, code: 110, browser: 88, terminal: 104 };
  for (const [name, port] of Object.entries(toolPorts)) placeStation(name, project(groundRoutes[name].at(-1)), port, 180, labelTops[name]);
  factory.classList.add('is-ready');
  const routes = Object.fromEntries(Object.entries(groundRoutes).map(([name, points]) => [name, points.map(project)]));
  const groundInbound = Object.fromEntries(clients.map(name => [name, [...groundRoutes[name], ...groundRoutes.tunnel.slice(1)]]));
  // Shared lanes are drawn once so branching workflows cannot darken rollers.
  const laneSegments = new Map();
  Object.values(groundRoutes).forEach(points => points.slice(1).forEach((b, index) => {
    const a = points[index];
    const key = [a.join(','), b.join(',')].sort().join(':');
    laneSegments.set(key, { a, b });
  }));
  function makePath(points) {
    let length = 0;
    const segments = points.slice(1).map((b, index) => {
      const a = points[index];
      const size = Math.hypot(b[0] - a[0], b[1] - a[1]);
      const segment = { a, b, start: length, size };
      length += size;
      return segment;
    });
    return { points, segments, length };
  }
  const paths = Object.fromEntries(Object.entries(routes).map(([name, points]) => [name, makePath(points)]));
  const incoming = name => makePath([...routes[name], ...routes.tunnel.slice(1)]);
  const inboundPaths = Object.fromEntries(clients.map(name => [name, incoming(name)]));
  function pointAt(path, fraction) {
    const distance = Math.max(0, Math.min(1, fraction)) * path.length;
    const segment = path.segments.find(s => distance <= s.start + s.size) || path.segments.at(-1);
    const p = (distance - segment.start) / segment.size;
    return [segment.a[0] + (segment.b[0] - segment.a[0]) * p, segment.a[1] + (segment.b[1] - segment.a[1]) * p];
  }
  function stroke(points, width, color) {
    ctx.beginPath();
    points.forEach((p, index) => index ? ctx.lineTo(...p) : ctx.moveTo(...p));
    ctx.lineWidth = width;
    ctx.strokeStyle = color;
    ctx.lineJoin = 'miter';
    ctx.miterLimit = 2;
    ctx.lineCap = 'butt';
    ctx.stroke();
  }
  const colors = { edge: '#9ca698', track: '#edf0e7', ribs: '#c5cebc', pipe: '#e9e7ed', purple: '#9b85b6', green: '#8ba778' };
  function paintRoutes() {
    ctx.clearRect(0, 0, WIDTH, HEIGHT);
    ctx.save();
    ctx.transform(1, ISO_SLOPE, 1, -ISO_SLOPE, ...ORIGIN);
    const lanes = Object.values(groundRoutes);
    // Paint all outlines before any infill to open T-junctions cleanly.
    for (const points of lanes) stroke(points, LANE_WIDTH, colors.edge);
    for (const points of lanes) stroke(points, LANE_WIDTH - BORDER_WIDTH * 2, colors.track);
    // Tunnel uses the same cross-section as every branch; tint identifies it.
    stroke(groundRoutes.tunnel, LANE_WIDTH - BORDER_WIDTH * 2, colors.pipe);
    const half = LANE_WIDTH / 2 - BORDER_WIDTH;
    for (const { a, b } of laneSegments.values()) {
      const length = Math.abs(b[0] - a[0]) + Math.abs(b[1] - a[1]);
      const du = (b[0] - a[0]) / length;
      const dv = (b[1] - a[1]) / length;
      // Leave the joint itself clear. Crossbars follow the other ground axis,
      // not a screen-space perpendicular that would break the perspective.
      for (let d = LANE_WIDTH; d <= length - LANE_WIDTH; d += 14) {
        const u = a[0] + du * d, v = a[1] + dv * d;
        stroke([[u - dv * half, v + du * half], [u + dv * half, v - du * half]], 1, colors.ribs);
      }
    }
    // Directional emphasis is visual only; the box trajectory is the source
    // of truth for when a request is delivered and a result is returned.
    const active = phase === 0 || phase === 6 ? groundInbound[client] : phase >= 2 && phase <= 4 ? groundRoutes[current] : null;
    if (active) {
      ctx.globalAlpha = .55;
      stroke(active, 2, phase >= 4 ? colors.green : colors.purple);
      ctx.globalAlpha = 1;
    }
    ctx.restore();
  }

  const parcel = document.createElement('img');
  parcel.src = 'assets/message-parcel.webp';
  parcel.alt = '';
  parcel.className = 'factory__parcel';
  parcel.draggable = false;
  parcelLayer.appendChild(parcel);
  const secondaryParcels = [5300, 10600].map(offset => {
    const element = parcel.cloneNode();
    element.classList.add('factory__parcel--secondary');
    parcelLayer.appendChild(element);
    return { element, offset };
  });
  let current = 'code';
  let client = 'chatgpt';
  let elapsed = 1900;
  let paused = reduced.matches;
  let visible = true;
  let frameId = null;
  let lastFrame = 0;
  let lastPaint = 0;
  let phase = -1;
  let sceneWidth = scene.getBoundingClientRect().width;
  let sceneHeight = sceneWidth * HEIGHT / WIDTH;
  const phaseEnds = [.20, .25, .46, .59, .80, .85, 1];

  function setPhase(next, force = false) {
    if (!force && next === phase) return;
    phase = next;
    factory.dataset.phase = String(phase);
    paintRoutes();
  }
  function render() {
    const portion = (elapsed % DURATION) / DURATION;
    const next = phaseEnds.findIndex(end => portion < end);
    setPhase(next);
    const start = phase === 0 ? 0 : phaseEnds[phase - 1];
    const part = (portion - start) / (phaseEnds[phase] - start);
    placeParcel(parcel, phase, part, 1, client, current);
    const working = new Set();
    const markWorking = (stage, source, tool) => working.add(stage === 0 || stage === 6 ? source : stage === 3 ? tool : 'luti');
    markWorking(phase, client, current);
    // Each AI has its own complete round trip, all passing through Luti.
    for (const [index, packet] of secondaryParcels.entries()) {
      const fraction = ((elapsed + packet.offset) % DURATION) / DURATION;
      const stage = phaseEnds.findIndex(end => fraction < end);
      const begin = stage === 0 ? 0 : phaseEnds[stage - 1];
      const source = clients[(clients.indexOf(client) + index + 1) % clients.length];
      const turn = Math.floor((elapsed + packet.offset) / DURATION);
      const tool = toolNames[(toolNames.indexOf(current) + index + 1 + turn) % toolNames.length];
      placeParcel(packet.element, stage, (fraction - begin) / (phaseEnds[stage] - begin), .85, source, tool);
      markWorking(stage, source, tool);
    }
    nodes.forEach(node => node.classList.toggle('is-working', working.has(node.dataset.client || node.dataset.node)));
  }
  function placeParcel(element, stage, fraction, opacity, source, tool) {
    const moving = [0, 2, 4, 6].includes(stage);
    element.hidden = !moving;
    if (!moving) return;
    const path = stage === 0 || stage === 6 ? inboundPaths[source] : paths[tool];
    const p = pointAt(path, stage >= 4 ? 1 - fraction : fraction);
    // The parcel's ground footprint is centered at (20, 30) in its 39×42
    // sprite. Align that footprint, not the image box or its lowest corner.
    element.style.transform = `translate3d(${(p[0] / WIDTH * sceneWidth).toFixed(2)}px, ${(p[1] / HEIGHT * sceneHeight).toFixed(2)}px, 0) translate(-51.282%, -71.429%)`;
    element.style.opacity = (opacity * Math.min(1, fraction * 20, (1 - fraction) * 20)).toFixed(3);
    element.dataset.direction = stage >= 4 ? 'return' : 'request';
    element.dataset.client = source;
    element.dataset.tool = tool;
  }

  function frame(now) {
    if (!lastFrame) lastFrame = now;
    elapsed += Math.min(now - lastFrame, 100);
    lastFrame = now;
    if (now - lastPaint >= 30) { render(); lastPaint = now; }
    frameId = requestAnimationFrame(frame);
  }
  function syncPlayback() {
    const playing = !paused && visible && !document.hidden;
    if (frameId !== null) cancelAnimationFrame(frameId);
    frameId = null;
    lastFrame = 0;
    if (playing) frameId = requestAnimationFrame(frame);
    factory.dataset.motion = paused ? 'paused' : 'playing';
  }
  function updateLabels() {
    nodes.forEach(node => node.setAttribute('aria-pressed', String(node.dataset.client ? node.dataset.client === client : node.dataset.node === current)));
  }
  function restart() {
    elapsed = 1900;
    phase = -1;
    factory.dataset.task = current;
    factory.dataset.client = client;
    updateLabels();
    render();
  }
  nodes.forEach(node => node.addEventListener('click', () => {
    if (node.dataset.client) client = node.dataset.client;
    else if (toolNames.includes(node.dataset.node)) current = node.dataset.node;
    restart();
  }));
  document.addEventListener('visibilitychange', syncPlayback);
  reduced.addEventListener('change', event => { paused = event.matches; syncPlayback(); });
  new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; syncPlayback(); }, { threshold: 0 }).observe(factory);
  new ResizeObserver(([entry]) => {
    sceneWidth = entry.contentRect.width;
    sceneHeight = entry.contentRect.height;
    const density = Math.min(devicePixelRatio || 1, 2);
    canvas.width = Math.round(sceneWidth * density);
    canvas.height = Math.round(sceneHeight * density);
    ctx.setTransform(canvas.width / WIDTH, 0, 0, canvas.height / HEIGHT, 0, 0);
    paintRoutes(); render();
  }).observe(scene);
  i18n.on(() => { updateLabels(); setPhase(phase, true); syncPlayback(); });
  restart(); syncPlayback();
})();
