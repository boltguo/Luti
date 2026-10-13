/* A hand-built SVG workshop. Buildings, lanes and parcels share one coordinate
 * system; each request and its result travel through Tunnel and Luti. */
(() => {
  const factory = document.getElementById('factory');
  if (!factory) return;
  const scene = document.getElementById('factoryScene');
  const laneLayer = document.getElementById('factoryRoutes');
  const packetLayer = document.getElementById('factoryParcels');
  const stationLayer = document.getElementById('factoryStations');
  const nodes = [...stationLayer.querySelectorAll('[data-node]')];
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const compact = matchMedia('(max-width: 600px)');
  const NS = 'http://www.w3.org/2000/svg';
  const S = Math.tan(Math.PI / 6);
  const clients = ['chatgpt', 'claude', 'grok'];
  const tools = ['memory', 'code', 'terminal', 'browser'];
  const palette = {
    chatgpt: { ink: '#237b65', top: '#def2e7', front: '#87c9aa', side: '#54a98a', wash: '#ecf8f0' },
    claude: { ink: '#ba6645', top: '#fbe5d6', front: '#e8ac87', side: '#cc8561', wash: '#fff2e7' },
    grok: { ink: '#475464', top: '#cad3df', front: '#718095', side: '#465467', wash: '#edf1f6' },
    luti: { ink: '#8761b5', top: '#efe2fa', front: '#c7aadf', side: '#a184bf', wash: '#f6edfc' },
    memory: { ink: '#779250', top: '#edf2d9', front: '#bdcf90', side: '#99b273', wash: '#f5f8e9' },
    code: { ink: '#507ebc', top: '#e0edfc', front: '#9cbce9', side: '#729bce', wash: '#eef5fd' },
    terminal: { ink: '#ad8434', top: '#fcf0ce', front: '#e6c578', side: '#c7a054', wash: '#fff8e7' },
    browser: { ink: '#388d99', top: '#d9f2f2', front: '#91cdd0', side: '#5baeb8', wash: '#ecf9f8' },
  };
  const n = value => Math.round(value * 100) / 100;
  const P = (u, v, z = 0) => [n(u - v), n((u + v) * S - z)];
  const world = ([u, v]) => [n(u + v), n((u - v) * S)];
  const plane = ([x, y]) => [(x + y / S) / 2, (x - y / S) / 2];
  const add = (a, b) => [a[0] + b[0], a[1] + b[1]];
  function svg(tag, attrs, parent, text) {
    const node = document.createElementNS(NS, tag);
    for (const [key, value] of Object.entries(attrs || {})) node.setAttribute(key, value);
    if (text !== undefined) node.textContent = text;
    if (parent) parent.appendChild(node);
    return node;
  }
  function polygon(g, points, fill, stroke = '#728178', attrs = {}) {
    return svg('polygon', { points: points.map(p => p.map(n).join(',')).join(' '), fill, stroke, 'stroke-width': 1.25, 'stroke-linejoin': 'round', ...attrs }, g);
  }
  function line(g, a, b, color, width = 1.5) {
    return svg('path', { d: `M${a.map(n)}L${b.map(n)}`, fill: 'none', stroke: color, 'stroke-width': width, 'stroke-linecap': 'round' }, g);
  }
  function cube(g, u, v, z, w, d, h, c) {
    polygon(g, [P(u, v + d, z), P(u + w, v + d, z), P(u + w, v + d, z + h), P(u, v + d, z + h)], c.front, c.ink);
    polygon(g, [P(u + w, v + d, z), P(u + w, v, z), P(u + w, v, z + h), P(u + w, v + d, z + h)], c.side, c.ink);
    polygon(g, [P(u, v, z + h), P(u + w, v, z + h), P(u + w, v + d, z + h), P(u, v + d, z + h)], c.top, c.ink);
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
  function pad(g, c, u = 54, v = 50) {
    polygon(g, [P(-u, -v), P(u, -v), P(u, v), P(-u, v)].map(([x, y]) => [x + 3, y + 6]), '#edf0eb', 'none');
    polygon(g, [P(-u, -v), P(u, -v), P(u, v), P(-u, v)], '#fafbf8', '#d3ded4', { class: 'factory__pad' });
    line(g, P(-u + 8, v - 6), P(u - 8, v - 6), c.top, 3);
  }
  function dock(g, c, out = false) {
    if (out) {
      cube(g, 36, -19, 0, 16, 22, 28, c);
      side(g, 52, -16, 0, 16, 23, '#394b45', c.ink);
    } else {
      cube(g, -20, 35, 0, 24, 17, 28, c);
      front(g, -17, 52, 0, 18, 22, '#394b45', c.ink);
    }
  }
  function cylinder(g, x, y, r, h, c) {
    const ry = n(r * S);
    svg('path', { d: `M${x-r} ${y-h}V${y}a${r} ${ry} 0 0 0 ${r*2} 0V${y-h}Z`, fill: c.front, stroke: c.ink, 'stroke-width': 1.25 }, g);
    svg('path', { d: `M${x+r*.35} ${y-h}V${y+ry*.92}Q${x+r} ${y+ry*.55} ${x+r} ${y}V${y-h}Z`, fill: c.side, stroke: 'none' }, g);
    svg('ellipse', { cx: x, cy: y-h, rx: r, ry, fill: c.top, stroke: c.ink, 'stroke-width': 1.25 }, g);
    svg('path', { d: `M${x-r} ${y-h*.4}a${r} ${ry} 0 0 0 ${r*2} 0`, fill: 'none', stroke: c.ink, 'stroke-width': 1, opacity: .5 }, g);
  }
  const builders = {
    chatgpt(g, c) {
      pad(g, c);
      cylinder(g, 0, 2, 60, 61, c);
      svg('path', { d: 'M-60-59C-60-126 60-126 60-59Q0-24-60-59Z', fill: c.front, stroke: c.ink, 'stroke-width': 1.4 }, g);
      svg('path', { d: 'M-60-59Q0-90 60-59M0-109Q-26-83-21-42M0-109Q28-78 22-42M0-109V-38', fill: 'none', stroke: '#e8fff2', 'stroke-width': 2.5 }, g);
      svg('path', { d: 'M-53-65Q-47-96-14-103', fill: 'none', stroke: '#fff', 'stroke-width': 4, opacity: .65 }, g);
      const badge = svg('g', { transform: 'translate(-24 -19) scale(.8)' }, g);
      svg('circle', { r: 18, fill: c.ink }, badge);
      for (let i = 0; i < 6; i++) svg('ellipse', { cx: 0, cy: -6, rx: 6, ry: 10, transform: `rotate(${i*60})`, fill: 'none', stroke: '#ecfff4', 'stroke-width': 1.1 }, badge);
      dock(g, c, true);
    },
    claude(g, c) {
      pad(g, c, 65, 50);
      cube(g, -50, -34, 0, 100, 68, 58, c);
      cube(g, 19, -27, 58, 17, 15, 55, c);
      polygon(g, [P(21,-25,114), P(34,-25,114), P(34,-14,114), P(21,-14,114)], '#80513e', c.ink);
      for (let u = -50; u < 50; u += 33.33) {
        polygon(g, [P(u,-34,58),P(u+19,-34,89),P(u+19,34,89),P(u,34,58)], c.top, c.ink);
        polygon(g, [P(u+19,-34,89),P(u+33.33,-34,58),P(u+33.33,34,58),P(u+19,34,89)], c.side, c.ink);
        polygon(g, [P(u,34,58),P(u+19,34,89),P(u+33.33,34,58)], c.front, c.ink);
        front(g, u+6, 35, 62, 9, 11, '#fff5e8', c.ink);
      }
      for (let u = -41; u <= 18; u += 19) front(g, u, 35, 15, 10, 21, '#fff3df', c.ink);
      const emblem = face(g, -7, 36, 46);
      for (let i = 0; i < 8; i++) {
        const a = i * Math.PI / 4;
        line(emblem, [Math.cos(a)*4,Math.sin(a)*4], [Math.cos(a)*11,Math.sin(a)*11], c.ink, 2.8);
      }
      dock(g, c, true);
    },
    grok(g, c) {
      pad(g, c);
      cube(g, -32, -30, 0, 64, 60, 12, c);
      polygon(g, [P(-26,26,12),P(30,26,12),P(30,26,112),P(-26,26,78)], c.side, c.ink);
      polygon(g, [P(30,26,12),P(30,-23,12),P(30,-23,137),P(30,26,112)], c.front, c.ink);
      polygon(g, [P(-26,-23,103),P(30,-23,137),P(30,26,112),P(-26,26,78)], c.top, c.ink);
      const emblem = face(g, -7, 27, 63);
      svg('path', { d: 'M-12 14 15-14M-10-12-1-3M5 3 14 12', fill:'none',stroke:'#fff','stroke-width':4,'stroke-linecap':'round' }, emblem);
      line(g, [7,-120], [7,-155], c.ink, 2);
      svg('ellipse', { cx: 7, cy: -155, rx: 39, ry: 12, transform: 'rotate(-22 7 -155)', fill: 'none', stroke: c.ink, 'stroke-width': 2.6 }, g);
      svg('circle', { cx: 7, cy: -155, r: 5, fill: '#f8fcff', stroke: c.ink, 'stroke-width': 2 }, g);
      dock(g, c);
    },
    luti(g, c) {
      pad(g, c, 70, 61);
      cube(g, -48, -37, 0, 92, 74, 91, c);
      cube(g, -42, -31, 91, 80, 62, 13, c);
      for (let u = -32; u <= 12; u += 24) {
        polygon(g, [P(u,-16,105),P(u+16,-16,105),P(u+16,8,105),P(u,8,105)], '#f8f1ff', c.ink);
        line(g, P(u+8,-16,105), P(u+8,8,105), '#ccb7df', 1);
      }
      cube(g, -30, -27, 105, 13, 13, 38, c);
      svg('circle', { cx: P(-23,-20,151)[0], cy: P(-23,-20,151)[1], r: 4, fill: c.ink, class: 'factory__indicator' }, g);
      cube(g, 7, -27, 105, 10, 12, 24, c);
      cube(g, -35, 37, 0, 72, 17, 44, c);
      front(g, -20, 54, 0, 24, 34, '#604579', c.ink);
      front(g, -16, 55, 3, 16, 26, '#e3d0f3', c.ink);
      for (let u = -37; u <= 15; u += 26) front(g, u, 38, 57, 14, 15, '#fff9ff', c.ink);
      cube(g, 44, -27, 0, 16, 37, 39, c);
      side(g, 60, -19, 0, 22, 29, '#604579', c.ink);
      const mark = face(g, 7, 55, 33);
      svg('path', { d:'M0 0v21h14', fill:'none', stroke:'#fff', 'stroke-width':5, 'stroke-linejoin':'round' }, mark);
    },
    memory(g, c) {
      pad(g, c, 61, 54);
      const tanks = [[P(-26,-19)[0],P(-26,-19)[1],23,77], [P(25,-20)[0],P(25,-20)[1],25,109], [P(-2,25)[0],P(-2,25)[1],25,72]];
      for (const [x,y,r,h] of tanks) {
        cylinder(g,x,y,r,h,c);
        svg('ellipse', { cx:x,cy:y-h-1,rx:r*.48,ry:r*.48*S,fill:'#fbfdf4',stroke:c.ink,'stroke-width':1 },g);
        for(let k=0;k<3;k++) line(g,[x-9,y-h+20+k*8],[x+2,y-h+24+k*8],c.ink,1.2);
      }
      svg('path',{d:'M-37 22v15l26 15 21-12',fill:'none',stroke:c.ink,'stroke-width':7,'stroke-linejoin':'round'},g);
      svg('path',{d:'M-37 22v15l26 15 21-12',fill:'none',stroke:c.top,'stroke-width':4,'stroke-linejoin':'round'},g);
      dock(g,c);
    },
    code(g,c) {
      pad(g,c,60,54);
      for (const [v,z] of [[-26,100],[-4,89],[20,76]]) {
        cube(g,-40,v,0,81,7,z,c);
        front(g,-33,v+8,z-45,58,34,'#f7fbff',c.ink);
        for(let k=0;k<3;k++) front(g,-27,v+9,z-22-k*7,34-k*5,2,c.side,'none');
      }
      const folder=[P(-45,43,0),P(47,43,0),P(47,43,66),P(1,43,66),P(-12,43,84),P(-45,43,84)];
      polygon(g,folder,c.front,c.ink);
      const mark=face(g,0,44,41);
      svg('path',{d:'m-11-10-12 10 12 10m20-20 12 10-12 10m-7-24-8 28',fill:'none',stroke:'#f9fcff','stroke-width':3,'stroke-linecap':'round','stroke-linejoin':'round'},mark);
      dock(g,c);
    },
    terminal(g,c) {
      pad(g,c,61,52);
      cube(g,-44,-36,0,88,72,58,c);
      for (const u of [-26,4]) {
        cube(g,u,-23,58,23,23,10,c);
        const [x,y]=P(u+11.5,-11.5,69);
        svg('ellipse',{cx:x,cy:y,rx:12,ry:7,fill:c.ink},g);
        for(let i=0;i<3;i++) svg('ellipse',{cx:x,cy:y-2,rx:2,ry:5,transform:`rotate(${i*120} ${x} ${y})`,fill:c.top},g);
      }
      front(g,-34,37,14,62,32,'#49513f',c.ink);
      const screen=face(g,-17,38,39);
      svg('path',{d:'m0 0 9 7-9 7m16 2h15',fill:'none',stroke:'#ffefb1','stroke-width':2.5,'stroke-linecap':'round','stroke-linejoin':'round'},screen);
      for(let v=-22;v<22;v+=9) side(g,45,v,14,4,26,c.ink,'none');
      cube(g,26,-28,58,11,17,31,c);
      dock(g,c);
    },
    browser(g,c) {
      pad(g,c,73,54);
      cube(g,-55,4,13,110,10,97,c);
      const display=face(g,-48,15,102);
      svg('rect',{width:96,height:80,rx:2,fill:'#f5fdfb'},display);
      svg('path',{d:'M0 15h96',stroke:c.side,'stroke-width':1},display);
      for(const [x,color] of [[7,'#d89487'],[15,'#e7c583'],[23,'#85bca7']]) svg('circle',{cx:x,cy:7,r:2.3,fill:color},display);
      svg('rect',{x:6,y:23,width:31,height:47,rx:2,fill:c.top},display);
      svg('rect',{x:45,y:23,width:44,height:22,rx:3,fill:c.front},display);
      for(let i=0;i<3;i++) svg('rect',{x:45,y:52+i*8,width:40-i*7,height:3,rx:1,fill:c.side,opacity:.65},display);
      svg('path',{d:'m59 32 7 4-7 4Z',fill:'#fff'},display);
      cube(g,-38,20,0,77,27,6,c);
      for(let u=-30;u<31;u+=12) for(let v=24;v<42;v+=8) polygon(g,[P(u,v,7),P(u+8,v,7),P(u+8,v+5,7),P(u,v+5,7)],'#f0fcfa',c.side);
      dock(g,c);
    },
  };
  const ports = {
    chatgpt: { out:P(52,-8) }, claude: { out:P(52,-8) }, grok:{ out:P(-8,52) },
    luti:{ in:P(-8,54),out:P(60,-8) },
    memory:{in:P(-8,52)},code:{in:P(-8,52)},terminal:{in:P(-8,52)},browser:{in:P(-8,52)},
  };
  for(const node of nodes) {
    const name=node.dataset.node,c=palette[name];
    node.style.setProperty('--tone',c.ink);
    node.style.setProperty('--wash',c.wash);
    builders[name](node.querySelector('.factory__art'),c);
    node.querySelector('.factory__label').setAttribute('y',name==='luti'?91:83);
  }

  let groundRoutes={},paths={},inbound={},positions={};
  let selectedClient='chatgpt',selectedTool='code',elapsed=1800;
  let activeLine,frameId=null,lastFrame=0,lastPaint=0,visible=true,lastStage=-1;
  const DURATION=18000,ends=[.20,.25,.46,.59,.80,.85,1];
  const packets=clients.map((source,index)=>{
    const element=svg('g',{class:'factory__parcel',style:`color:${palette[source].ink}`},packetLayer);
    svg('use',{href:'#factoryParcel',x:-20,y:-33,width:40,height:45},element);
    return {element,offset:index*5600};
  });
  function path(points) {
    let length=0;
    const segments=points.slice(1).map((b,i)=>{
      const a=points[i],size=Math.hypot(b[0]-a[0],b[1]-a[1]);
      const part={a,b,start:length,size};length+=size;return part;
    }).filter(s=>s.size>0);
    return {segments,length};
  }
  function pointAt(route,t) {
    const distance=Math.max(0,Math.min(1,t))*route.length;
    const s=route.segments.find(s=>distance<=s.start+s.size)||route.segments.at(-1);
    const f=(distance-s.start)/s.size;
    return [s.a[0]+(s.b[0]-s.a[0])*f,s.a[1]+(s.b[1]-s.a[1])*f];
  }
  const pathData=points=>points.map((p,i)=>(i?'L':'M')+p.map(n).join(' ')).join('');
  function isoRoute(a,b,first='u') {
    const u=plane(a),v=plane(b);
    return [u,first==='u'?[v[0],u[1]]:[u[0],v[1]],v];
  }
  function position(name,gate,port) {
    positions[name]=[gate[0]-port[0],gate[1]-port[1]];
  }
  function layout() {
    positions={};
    if(!compact.matches) {
      const origin=[490,412],project=p=>add(world(p),origin);
      const clientLanes={
        chatgpt:[[-255,0],[0,0]],
        claude:[[-60,-210],[0,-210],[0,0]],
        grok:[[120,-160],[120,-240],[0,-240],[0,-210],[0,0]],
        tunnel:[[0,0],[0,215]],
      };
      groundRoutes=Object.fromEntries(Object.entries(clientLanes).map(([name,ps])=>[name,ps.map(p=>plane(project(p)))]));
      for(const name of clients) position(name,project(clientLanes[name][0]),ports[name].out);
      position('luti',project(clientLanes.tunnel.at(-1)),ports.luti.in);
      const outlet=add(positions.luti,ports.luti.out);
      const local={
        memory:[[0,0],[100,0],[100,290]],
        code:[[0,0],[100,0],[280,0],[280,290]],
        browser:[[0,0],[100,0],[280,0],[440,0],[440,100]],
        terminal:[[0,0],[100,0],[100,-150],[295,-150],[295,-50]],
      };
      for(const [name,ps] of Object.entries(local)) {
        groundRoutes[name]=ps.map(p=>plane(add(world(p),outlet)));
        position(name,world(groundRoutes[name].at(-1)),ports[name].in);
      }
      scene.setAttribute('viewBox','0 0 1600 650');
      setBoundary(644,22,953,580,674,16,85,84);
      document.getElementById('factoryTunnel').setAttribute('transform','translate(537 294)');
    } else {
      // Reflow the same vector buildings, keeping every bend on the same
      // isometric axes. Only topology coordinates change, never SVG scale axes.
      positions={chatgpt:[140,205],claude:[437,173],grok:[745,215],luti:[410,514],memory:[699,675],code:[204,862],terminal:[444,1050],browser:[736,988]};
      const gate=name=>add(positions[name],ports[name].out);
      const junction=[232,405],entry=add(positions.luti,ports.luti.in),exit=add(positions.luti,ports.luti.out);
      groundRoutes={
        chatgpt:isoRoute(gate('chatgpt'),junction),
        claude:isoRoute(gate('claude'),junction,'v'),
        grok:isoRoute(gate('grok'),junction,'v'),
        tunnel:isoRoute(junction,entry),
      };
      const trunk=isoRoute(exit,[446,734]);
      for(const name of tools) {
        const target=add(positions[name],ports[name].in);
        const approach=[target[0]-72,target[1]+72*S];
        groundRoutes[name]=[...trunk,...isoRoute(world(trunk.at(-1)),approach).slice(1),plane(target)];
      }
      scene.setAttribute('viewBox','0 0 900 1170');
      setBoundary(55,367,789,779,84,354,50,43);
      document.getElementById('factoryTunnel').setAttribute('transform','translate(141 474)');
    }
    for(const node of nodes) node.setAttribute('transform',`translate(${positions[node.dataset.node].map(n).join(' ')})`);
    // A far station is painted before a near one, including its dock and label.
    nodes.slice().sort((a,b)=>positions[a.dataset.node][1]-positions[b.dataset.node][1]).forEach(node=>stationLayer.appendChild(node));
    paths=Object.fromEntries(Object.entries(groundRoutes).map(([name,ps])=>[name,path(ps.map(world))]));
    inbound=Object.fromEntries(clients.map(name=>[name,path([...groundRoutes[name],...groundRoutes.tunnel.slice(1)].map(world))]));
    drawLanes();lastStage=-1;render();
  }
  function setBoundary(x,y,width,height,wx,wy,rx,ry) {
    const boundary=document.getElementById('factoryBoundary');
    Object.entries({x,y,width,height}).forEach(([key,value])=>boundary.setAttribute(key,value));
    for(const [id,px,py] of [['factoryWorkspace',wx,wy],['factoryRemote',rx,ry]]) {
      const el=document.getElementById(id);el.setAttribute('x',px);el.setAttribute('y',py);
    }
  }
  function drawLanes() {
    laneLayer.replaceChildren();
    const ground=svg('g',{transform:`matrix(1 ${S} 1 ${-S} 0 0)`,fill:'none','stroke-linejoin':'miter','stroke-miterlimit':2},laneLayer);
    const all=Object.values(groundRoutes);
    for(const ps of all) svg('path',{d:pathData(ps),stroke:'#bdcbbd','stroke-width':25},ground);
    for(const ps of all) svg('path',{d:pathData(ps),stroke:'#f0f4eb','stroke-width':22},ground);
    svg('path',{d:pathData(groundRoutes.tunnel),stroke:'#ece4f5','stroke-width':22},ground);
    const segments=new Map();
    all.forEach(ps=>ps.slice(1).forEach((b,i)=>{const a=ps[i];segments.set([a.map(n).join(','),b.map(n).join(',')].sort().join(':'),{a,b});}));
    let ribs='';
    for(const {a,b} of segments.values()) {
      const length=Math.hypot(b[0]-a[0],b[1]-a[1]);
      if(length<30)continue;
      const du=(b[0]-a[0])/length,dv=(b[1]-a[1])/length;
      for(let d=22;d<length-22;d+=17) {
        const u=a[0]+du*d,v=a[1]+dv*d;
        ribs+=`M${n(u-dv*10)} ${n(v+du*10)}L${n(u+dv*10)} ${n(v-du*10)}`;
      }
    }
    svg('path',{d:ribs,stroke:'#d0dccc','stroke-width':1},ground);
    activeLine=svg('path',{'stroke-width':2.5,'stroke-dasharray':'5 11',opacity:.6},ground);
  }
  function phaseAt(time) {
    const fraction=(time%DURATION)/DURATION;
    const stage=ends.findIndex(end=>fraction<end),start=stage===0?0:ends[stage-1];
    return {stage,fraction:(fraction-start)/(ends[stage]-start)};
  }
  function render() {
    const working=new Set();
    for(const [index,packet] of packets.entries()) {
      const time=elapsed+packet.offset,{stage,fraction}=phaseAt(time);
      const source=clients[(clients.indexOf(selectedClient)+index)%clients.length];
      const tool=index===0?selectedTool:tools[(tools.indexOf(selectedTool)+index+Math.floor(time/DURATION))%tools.length];
      const moving=[0,2,4,6].includes(stage);
      packet.element.style.display=moving?'':'none';
      packet.element.style.color=palette[source].ink;
      packet.element.dataset.client=source;packet.element.dataset.tool=tool;
      packet.element.dataset.direction=stage>=4?'return':'request';
      if(moving) {
        const p=pointAt(stage===0||stage===6?inbound[source]:paths[tool],stage>=4?1-fraction:fraction);
        packet.element.setAttribute('transform',`translate(${p.map(n).join(' ')})`);
        packet.element.style.opacity=n(Math.min(1,fraction*18,(1-fraction)*18));
      }
      working.add(stage===0||stage===6?source:stage===3?tool:'luti');
      if(index===0&&stage!==lastStage) {
        lastStage=stage;
        const ps=stage===0||stage===6?[...groundRoutes[source],...groundRoutes.tunnel.slice(1)]:groundRoutes[tool];
        activeLine.setAttribute('d',pathData(ps));activeLine.setAttribute('stroke',palette[stage===0||stage===6?source:tool].ink);
        factory.dataset.phase=stage;
      }
    }
    for(const node of nodes)node.classList.toggle('is-working',working.has(node.dataset.node));
  }
  function updateLabels() {
    for(const node of nodes) {
      const name=node.dataset.node;
      node.setAttribute('aria-label',node.querySelector('.factory__label').textContent.trim());
      node.setAttribute('aria-pressed',String(name===selectedClient||name===selectedTool));
    }
  }
  function choose(node) {
    const name=node.dataset.node;
    if(clients.includes(name))selectedClient=name;
    if(tools.includes(name))selectedTool=name;
    elapsed=1800;lastStage=-1;
    factory.dataset.client=selectedClient;factory.dataset.task=selectedTool;
    updateLabels();render();
  }
  function frame(now) {
    if(!lastFrame)lastFrame=now;
    elapsed+=Math.min(now-lastFrame,100);lastFrame=now;
    if(now-lastPaint>=32){render();lastPaint=now;}
    frameId=requestAnimationFrame(frame);
  }
  function syncPlayback() {
    if(frameId!==null)cancelAnimationFrame(frameId);
    frameId=null;lastFrame=0;
    const playing=!reduced.matches&&visible&&!document.hidden;
    if(playing)frameId=requestAnimationFrame(frame);
    factory.dataset.motion=playing?'playing':'paused';
  }
  nodes.forEach(node=>{
    node.addEventListener('click',()=>choose(node));
    node.addEventListener('keydown',event=>{if(event.key==='Enter'||event.key===' '){event.preventDefault();choose(node);}});
  });
  compact.addEventListener('change',layout);
  reduced.addEventListener('change',syncPlayback);
  document.addEventListener('visibilitychange',syncPlayback);
  new IntersectionObserver(([entry])=>{visible=entry.isIntersecting;syncPlayback();}).observe(factory);
  window.lutiI18n.on(updateLabels);
  layout();updateLabels();syncPlayback();
})();
