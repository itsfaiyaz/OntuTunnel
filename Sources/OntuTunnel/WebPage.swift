// The browser dashboard page (one self-contained HTML file, no external assets).
enum WebPage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>OntuTunnel</title>
<style>
:root{--bg:#f5f7fb;--panel:#fff;--panel2:#f0f3f8;--text:#0e1726;--muted:#64748b;--line:#e3e8f0;--ontu:#3e8bff;--green:#16a34a;--orange:#d97706;--red:#dc2626;--gray:#94a3b8;--mono:ui-monospace,SFMono-Regular,Menlo,monospace}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){--bg:#050c1b;--panel:#0b1529;--panel2:#0f1c35;--text:#e6edf8;--muted:#8a9ab5;--line:#1c2a45}}
:root[data-theme=dark]{--bg:#050c1b;--panel:#0b1529;--panel2:#0f1c35;--text:#e6edf8;--muted:#8a9ab5;--line:#1c2a45}
*{box-sizing:border-box}html,body{margin:0}body{background:var(--bg);color:var(--text);font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Inter,sans-serif}
a{color:inherit}button{font:inherit;font-size:13px;padding:7px 12px;border-radius:9px;border:1px solid var(--line);background:var(--panel);color:var(--text);cursor:pointer;white-space:nowrap}
button:hover{border-color:var(--ontu)}button.primary{background:var(--ontu);border-color:var(--ontu);color:#fff}button.ghost{background:transparent}button.danger{color:var(--red)}
input{font:inherit;padding:8px 11px;border-radius:9px;border:1px solid var(--line);background:var(--panel);color:var(--text);min-width:0;outline:none}input:focus{border-color:var(--ontu)}
.top{position:sticky;top:0;z-index:5;background:color-mix(in srgb,var(--bg) 88%,transparent);backdrop-filter:blur(10px);border-bottom:1px solid var(--line)}
.top .in{max-width:1280px;margin:0 auto;padding:12px 20px;display:flex;gap:10px;align-items:center;flex-wrap:wrap}
.brand{display:flex;align-items:center;gap:9px;font-weight:700;font-size:17px;margin-right:6px}.brand svg{width:26px;height:26px}
.pill{display:inline-flex;align-items:center;gap:6px;padding:3px 10px;border-radius:999px;font-size:12px;font-weight:600;background:color-mix(in srgb,var(--c) 15%,transparent)}
.pill:before{content:"";width:7px;height:7px;border-radius:50%;background:var(--c);box-shadow:0 0 0 3px color-mix(in srgb,var(--c) 22%,transparent)}
.ok{--c:var(--green)}.warning{--c:var(--orange)}.failed{--c:var(--red)}.unknown,.checking,.off{--c:var(--gray)}
main{max-width:1280px;margin:0 auto;padding:18px 20px 40px;display:grid;gap:16px}
.stats{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}@media (max-width:900px){.stats{grid-template-columns:repeat(2,1fr)}}
.tile{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:14px 16px;position:relative;overflow:hidden}
.tile:before{content:"";position:absolute;left:0;top:14px;bottom:14px;width:3px;border-radius:2px;background:var(--c)}
.tile .lbl{font-size:11px;font-weight:700;letter-spacing:.08em;color:var(--muted);text-transform:uppercase}
.tile .big{font-size:22px;font-weight:700;margin-top:4px}.tile .sub{font:12px var(--mono);color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.panel{background:var(--panel);border:1px solid var(--line);border-radius:14px}
.ph{display:flex;align-items:center;gap:10px;padding:12px 14px;border-bottom:1px solid var(--line);flex-wrap:wrap}.ph h2{font-size:15px;margin:0}
.count{font:12px var(--mono);padding:1px 8px;border-radius:999px;background:var(--panel2);color:var(--muted)}
.chips{display:flex;gap:4px;background:var(--panel2);padding:3px;border-radius:10px}.chips button{border:0;background:transparent;padding:5px 10px}.chips button.on{background:var(--panel);box-shadow:0 1px 2px rgba(0,0,0,.15)}
table{width:100%;border-collapse:collapse}th{font-size:11px;letter-spacing:.06em;text-transform:uppercase;color:var(--muted);text-align:left;font-weight:700;padding:9px 14px;border-bottom:1px solid var(--line)}
td{padding:9px 14px;border-bottom:1px solid var(--line);vertical-align:middle}tr:last-child td{border-bottom:0}tbody tr{cursor:pointer}tbody tr:hover{background:var(--panel2)}tbody tr.sel{background:color-mix(in srgb,var(--ontu) 12%,transparent)}
.dot{width:9px;height:9px;border-radius:50%;background:var(--c);display:inline-block;box-shadow:0 0 0 3px color-mix(in srgb,var(--c) 20%,transparent)}
.mono{font-family:var(--mono);font-size:12.5px}.muted{color:var(--muted)}.name{font-weight:600}
.health{display:flex;gap:10px}.health span{display:inline-flex;align-items:center;gap:4px;font:11px var(--mono);color:var(--muted)}.health i{width:8px;height:8px;border-radius:50%;background:var(--c);display:inline-block}
.toggle{position:relative;width:36px;height:20px;border-radius:999px;background:var(--gray);border:0;padding:0;flex:none}.toggle.on{background:var(--green)}
.toggle:after{content:"";position:absolute;top:3px;left:3px;width:14px;height:14px;border-radius:50%;background:#fff;transition:left .15s}.toggle.on:after{left:19px}
.layout{display:grid;grid-template-columns:1fr;gap:16px}.layout.withd{grid-template-columns:1fr 340px}@media (max-width:1000px){.layout.withd{grid-template-columns:1fr}}
.drawer{padding:16px;display:grid;gap:12px;align-content:start}.drawer h3{margin:0;font-size:18px}
.srow{display:flex;justify-content:space-between;gap:10px;padding:9px 0;border-bottom:1px solid var(--line)}.srow:last-child{border:0}
form.add{display:grid;grid-template-columns:1.2fr 1.8fr .6fr 1fr auto;gap:8px;padding:14px}@media (max-width:760px){form.add{grid-template-columns:1fr}}
.ports{display:grid;grid-template-columns:repeat(auto-fill,minmax(190px,1fr));gap:8px;padding:14px}
.port{border:1px solid var(--line);border-radius:10px;padding:7px 10px;display:flex;justify-content:space-between;align-items:center;gap:6px;background:var(--panel2)}
.port button{padding:4px 9px;font-size:12px}details>summary{cursor:pointer;color:var(--muted);padding:0 14px 12px}
.log{font:12px var(--mono);white-space:pre-wrap;max-height:260px;overflow:auto;padding:0 14px 14px}.err{color:var(--red)}
.empty{padding:40px;text-align:center;color:var(--muted)}#msg{color:var(--red);font-size:13px;padding:0 14px 10px}.hint{color:var(--muted);font-size:12.5px;padding:0 14px 12px}
</style>
<script>
function getTheme(){try{return localStorage.getItem('ot-theme')||'auto'}catch(e){return 'auto'}}
function setTheme(t){try{localStorage.setItem('ot-theme',t)}catch(e){}if(t==='auto')document.documentElement.removeAttribute('data-theme');else document.documentElement.setAttribute('data-theme',t);var b=document.getElementById('themeBtn');if(b)b.textContent={auto:'◐ Auto',light:'☀ Light',dark:'☾ Dark'}[t]}
function nextTheme(){setTheme({auto:'light',light:'dark',dark:'auto'}[getTheme()])}
setTheme(getTheme());
</script>
</head>
<body>
<div class="top"><div class="in">
  <div class="brand"><svg viewBox="0 0 32 32"><rect width="32" height="32" rx="8" fill="#0a1b3c"/><path d="M6 24a10 10 0 0 1 20 0" fill="none" stroke="#3e8bff" stroke-opacity=".45" stroke-width="2.5" stroke-linecap="round"/><path d="M10 13h12m-3-3 3 3-3 3M22 19H10m3-3-3 3 3 3" fill="none" stroke="#3e8bff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>OntuTunnel</div>
  <span id="mode" class="pill unknown">…</span>
  <span style="flex:1"></span>
  <input id="q" placeholder="Search sites, domains, ports" oninput="render(last)" style="width:240px">
  <button class="ghost" id="themeBtn" onclick="nextTheme()" title="Theme">◐ Auto</button>
  <button class="ghost" onclick="act('refresh')" title="Refresh">↻</button>
  <button onclick="act('sync')">Sync</button>
  <button id="conn" class="primary" onclick="act(window.connected?'disconnect':'connect')">…</button>
</div></div>
<main>
  <section class="stats" id="stats"></section>
  <div class="layout" id="layout">
    <section class="panel">
      <div class="ph"><h2>Services</h2><span class="count" id="cnt">0</span><span style="flex:1"></span>
        <div class="chips" id="filters"></div>
        <button class="primary" onclick="toggleAdd()">+ Add service</button></div>
      <div id="addBox" style="display:none;border-bottom:1px solid var(--line)">
        <form class="add" onsubmit="addService(event)">
          <input id="fName" placeholder="Name (e.g. My Shop)"><input id="fDomain" list="bases" placeholder="Domain (e.g. shop.dev.example.com)">
          <input id="fPort" placeholder="Port" inputmode="numeric"><input id="fSite" placeholder="Frappe site (optional)"><button class="primary">Add</button>
        </form><datalist id="bases"></datalist><div class="hint" id="addHint"></div><div id="msg"></div>
      </div>
      <div id="tableBox"></div>
    </section>
    <aside class="panel drawer" id="drawer" style="display:none"></aside>
  </div>
  <section class="panel">
    <div class="ph"><h2>Running on this Mac</h2><span class="count" id="pcnt">0</span></div>
    <div class="ports" id="ports"></div>
    <details id="hiddenBox"><summary id="hiddenSum"></summary><div class="ports" id="hiddenPorts" style="padding-top:0"></div></details>
  </section>
  <section class="panel"><details><summary style="padding:12px 14px">Logs</summary><div id="logs" class="log"></div></details></section>
</main>
<script>
const esc=s=>String(s??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
let last=null,filter='All',sel=null;
const needs=s=>s.enabled&&(s.port=='closed'||!s.live.ok||!s.dns.ok);
const color=s=>!s.enabled?'off':s.port=='closed'?'failed':s.live.ok?'ok':'warning';
async function load(){try{const r=await fetch('/api/status',{cache:'no-store'});if(r.ok){last=await r.json();render(last)}}catch(e){}}
function render(d){if(!d)return;
  window.connected=d.connected;
  const m=document.getElementById('mode');m.className='pill '+(d.connected?'ok':d.ready?'failed':'unknown');
  m.textContent=d.modeTitle+(d.connected?' · connected':d.ready?' · disconnected':' · not set up');
  document.getElementById('conn').textContent=d.connected?'Stop':'Connect';
  const on=d.services.filter(s=>s.enabled),live=on.filter(s=>s.live.ok).length,att=d.services.filter(needs).length;
  const detail=d.mode=='relay'?(d.server.host+(d.server.ip?' · '+d.server.ip:'')):d.dnsTarget||'';
  const cv=c=>c=='ok'?'green':c=='warning'?'orange':c=='failed'?'red':'gray';
  document.getElementById('stats').innerHTML=[
    ['Connection',d.connected?'ok':d.ready?'failed':'off',d.connected?'Connected':d.ready?'Disconnected':'Not set up',detail],
    ['Live sites',!on.length?'off':live==on.length?'ok':'warning',live+' / '+on.length,'online over HTTPS'],
    ['Attention',att?'warning':'ok',att?att+' site'+(att>1?'s':''):'All good',att?'see Health':'nothing to fix'],
    ['This Mac','ok',d.network.publicIPv4||'—','LAN '+(d.network.localIPv4||'—')]
  ].map(([l,c,b,s])=>`<div class="tile" style="--c:var(--${cv(c)})"><div class="lbl">${l}</div><div class="big">${esc(b)}</div><div class="sub">${esc(s)}</div></div>`).join('');
  document.getElementById('filters').innerHTML=['All','Live','Needs attention','Offline'].map(f=>`<button class="${f==filter?'on':''}" onclick="filter='${f}';render(last)">${f}</button>`).join('');
  const q=document.getElementById('q').value.trim().toLowerCase();
  const rows=d.services.filter(s=>{const m=!q||(s.name+' '+s.domain+' '+s.localPort).toLowerCase().includes(q);
    return m&&(filter=='All'||(filter=='Live'&&s.enabled&&s.live.ok)||(filter=='Needs attention'&&needs(s))||(filter=='Offline'&&!s.enabled))});
  document.getElementById('cnt').textContent=d.services.length;
  const h=(c,t,l)=>`<span title="${esc(t)}"><i style="--c:var(--${c})"></i>${l}</span>`;
  const hc=x=>x.ok?'green':x.state=='failed'?'red':x.state=='warning'?'orange':'gray';
  document.getElementById('tableBox').innerHTML=!d.services.length?'<div class="empty">No services yet — click + Add service, or Publish a port below.</div>':
   !rows.length?'<div class="empty">Nothing matches.</div>':
   `<table><thead><tr><th></th><th>Name</th><th>Domain</th><th>Local</th><th>Health</th><th>Online</th></tr></thead><tbody>${rows.map(s=>`
    <tr class="${s.id==sel?'sel':''}" onclick="pick('${s.id}')">
      <td style="width:18px"><span class="dot ${color(s)}"></span></td>
      <td class="name">${esc(s.name||s.domain.split('.')[0])}</td>
      <td class="mono muted">${esc(s.domain)}</td>
      <td class="mono">:${s.localPort}</td>
      <td><div class="health">${h(s.port=='open'?'green':s.port=='closed'?'red':'gray','Local app '+(s.port=='open'?'running':'not running'),'app')}${h(hc(s.dns),'DNS: '+s.dns.text,'dns')}${h(s.enabled?hc(s.live):'gray','Internet: '+(s.live.ok?'live over HTTPS':s.live.text),'https')}</div></td>
      <td onclick="event.stopPropagation()"><button class="toggle ${s.enabled?'on':''}" onclick="act('toggle',{id:'${s.id}',on:${!s.enabled}})" aria-label="Online"></button></td>
    </tr>`).join('')}</tbody></table>`;
  drawer(d);
  const vis=d.ports.filter(p=>!p.hidden),hid=d.ports.filter(p=>p.hidden);document.getElementById('pcnt').textContent=vis.length;
  const pc=(p,hd)=>`<div class="port"><div><div class="mono" style="font-weight:700">:${p.port}</div><div class="muted" style="font-size:11.5px">${esc(p.process)}</div></div><div style="display:flex;gap:5px">${hd?`<button onclick="act('unhide',{port:${p.port}})">Unhide</button>`:(p.published?'<span class="pill ok">Live</span>':`<button onclick="prefill(${p.port},'${esc(p.process)}')">Publish</button>`)+`<button class="ghost" title="Hide" onclick="act('hide',{port:${p.port}})">⦸</button>`}</div></div>`;
  document.getElementById('ports').innerHTML=vis.map(p=>pc(p,false)).join('')||'<div class="muted">Nothing listening (or all hidden).</div>';
  document.getElementById('hiddenBox').style.display=hid.length?'':'none';
  document.getElementById('hiddenSum').textContent=`Hidden (${hid.length}) — `+hid.map(p=>p.process+' :'+p.port).join(', ');
  document.getElementById('hiddenPorts').innerHTML=hid.map(p=>pc(p,true)).join('');
  document.getElementById('bases').innerHTML=d.wildcards.map(w=>`<option value="name.${esc(w.base)}">`).join('');
  const ready=d.wildcards.filter(w=>w.check.ok).map(w=>'*.'+w.base);
  document.getElementById('addHint').textContent=(ready.length?'Under '+ready.join(', ')+' no DNS step is needed. ':'')+(d.dnsTarget?'Any other domain needs an A record → '+d.dnsTarget+'.':'');
  document.getElementById('logs').innerHTML=d.logs.slice().reverse().map(l=>`<div class="${l.error?'err':''}">${esc(l.time)} [${esc(l.source)}] ${esc(l.text)}</div>`).join('');
}
function drawer(d){const el=document.getElementById('drawer'),lay=document.getElementById('layout');const s=d.services.find(x=>x.id==sel);
  if(!s){el.style.display='none';lay.classList.remove('withd');return}
  el.style.display='';lay.classList.add('withd');
  const r=(k,c,v)=>`<div class="srow"><span>${k}</span><span class="pill ${c}">${esc(v)}</span></div>`;
  el.innerHTML=`<div style="display:flex;justify-content:space-between;align-items:start"><div><h3>${esc(s.name||s.domain)}</h3><a class="mono muted" href="${esc(s.url)}" target="_blank">${esc(s.domain)} ↗</a></div><button class="ghost" onclick="pick(null)">✕</button></div>
   <div>${r('Local app :'+s.localPort,s.port=='open'?'ok':s.port=='closed'?'failed':'unknown',s.port=='open'?'Running':s.port=='closed'?'Not running':'…')}
   ${r('DNS',s.dns.state,s.dns.ok?'OK':s.dns.text)}${r('Internet',s.enabled?s.live.state:'off',s.live.ok?'Live (HTTPS)':s.enabled?s.live.text:'Offline')}
   ${s.frappeSite?`<div class="srow"><span>Frappe site</span><span class="mono">${esc(s.frappeSite)}</span></div>`:''}</div>
   <a href="${esc(s.url)}" target="_blank"><button class="primary" style="width:100%">Open site</button></a>
   <div style="display:flex;gap:8px"><button style="flex:1" onclick="navigator.clipboard.writeText('${esc(s.url)}')">Copy URL</button>
   <button style="flex:1" onclick="act('toggle',{id:'${s.id}',on:${!s.enabled}})">${s.enabled?'Take offline':'Bring online'}</button></div>
   ${s.hasCommand?`<button onclick="act('${s.commandRunning?'stop':'start'}',{id:'${s.id}'})">${s.commandRunning?'Stop command':'Start command'}</button>`:''}
   <button class="danger" onclick="if(confirm('Delete ${esc(s.name||s.domain)}? It is also removed from the server.')){act('delete',{id:'${s.id}'});pick(null)}">Delete</button>`;}
function pick(id){sel=id;render(last)}
function toggleAdd(){const b=document.getElementById('addBox');b.style.display=b.style.display=='none'?'':'none';if(b.style.display=='')fName.focus()}
async function act(action,extra={}){const r=await fetch('/api/action',{method:'POST',headers:{'Content-Type':'application/json','X-OntuTunnel':'1'},body:JSON.stringify({action,...extra})});
  const j=await r.json().catch(()=>({}));document.getElementById('msg').textContent=j.error||'';setTimeout(load,400);setTimeout(load,3000)}
function prefill(port,proc){document.getElementById('addBox').style.display='';fPort.value=port;fName.value=proc+' on '+port;fDomain.focus()}
function addService(e){e.preventDefault();act('add',{name:fName.value,domain:fDomain.value,localPort:parseInt(fPort.value,10),frappeSite:fSite.value});fName.value=fDomain.value=fPort.value=fSite.value=''}
load();setInterval(load,4000);
</script>
</body>
</html>
"""#
}
