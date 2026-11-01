"""Шаг 2 замера: локальная страница разметки кластеров.

Слушаешь фрагмент — вписываешь, кто это. Без имён замер невозможен: именно по ним
считается «один и тот же человек в разных файлах».

Сервер на 127.0.0.1, данные никуда не уходят. Пишет ~/ASR/spkid-eval/labels.json
после каждого изменения, так что закрыть вкладку можно в любой момент.
"""

import json
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

OUT = Path(os.environ.get("SPKID_OUT", Path.home() / "ASR/spkid-eval"))
LABELS = OUT / "labels.json"
PORT = int(os.environ.get("SPKID_PORT", "8765"))


def guess_channel(rec: dict) -> str:
    """Догадка, а не истина: пользователь переопределяет в выпадашке."""
    if rec.get("src_channels") == 2:
        return "vks"          # стерео — почти всегда экспорт из ВКС
    if rec.get("src_sr") == 32000:
        return "phone"        # 32 кГц моно пишет наше приложение на iPhone
    return ""                 # 48 кГц моно бывает и Voice Memos, и перекодированной ВКС


def load_state() -> dict:
    records = []
    for p in sorted((OUT / "data").glob("*.json")):
        rec = json.loads(p.read_text(encoding="utf-8"))
        rec["speakers"] = [s for s in rec["speakers"] if not s["padded"]]
        if rec["speakers"]:
            records.append(rec)
    records.sort(key=lambda r: -r["duration"])
    labels = json.loads(LABELS.read_text(encoding="utf-8")) if LABELS.exists() else {}
    return {"records": records, "labels": labels,
            "guess": {r["slug"]: guess_channel(r) for r in records}}


PAGE = """<!doctype html><meta charset="utf-8"><title>Разметка спикеров</title>
<style>
 :root{color-scheme:light dark}
 body{font:14px/1.5 -apple-system,system-ui,sans-serif;margin:0;padding:24px;max-width:1400px}
 h1{font-size:20px;margin:0 0 4px}
 .sub{opacity:.65;margin-bottom:20px}
 .bar{position:sticky;top:0;background:Canvas;padding:10px 0;border-bottom:1px solid #8884;
      margin-bottom:16px;z-index:2;display:flex;gap:16px;align-items:center;flex-wrap:wrap}
 .file{border:1px solid #8884;border-radius:10px;margin-bottom:14px;overflow:hidden}
 .fhead{display:flex;gap:12px;align-items:center;padding:10px 14px;background:#8881;flex-wrap:wrap}
 .fname{font-weight:600}
 .meta{opacity:.6;font-size:12px}
 .spk{display:flex;gap:12px;align-items:center;padding:9px 14px;border-top:1px solid #8883;
      flex-wrap:wrap}
 .lab{width:96px;font-variant-numeric:tabular-nums}
 .dur{width:88px;opacity:.7;font-size:12px;font-variant-numeric:tabular-nums}
 audio{height:32px;width:168px}
 input[type=text]{padding:5px 8px;border-radius:6px;border:1px solid #8886;background:Canvas;
                  color:CanvasText;width:180px}
 button{padding:5px 10px;border-radius:6px;border:1px solid #8886;background:Canvas;
        color:CanvasText;cursor:pointer}
 button.on{background:#3b82f6;color:#fff;border-color:#3b82f6}
 select{padding:4px 6px;border-radius:6px;background:Canvas;color:CanvasText;border:1px solid #8886}
 .done{opacity:.55}
</style>
<h1>Разметка спикеров</h1>
<div class="sub">Послушай фрагмент и впиши, кто это. Одинаковые имена в разных файлах = один
человек — на этом и держится замер. Сохраняется само.</div>
<div class="bar">
  <b id="progress">…</b>
  <span class="meta" id="names">…</span>
  <span class="meta">«я» — твой голос. «смесь» — в кластере слышно двоих, такой из замера
  исключается. Не узнал — оставь пустым.</span>
</div>
<div id="app"></div>
<script>
let S=null, names=new Set();
const key=(s,l)=>s+"|"+l;
const save=()=>fetch("/api/labels",{method:"POST",headers:{"Content-Type":"application/json"},
                                   body:JSON.stringify(S.labels)}).then(progress);
function progress(){
  const tot=S.records.reduce((a,r)=>a+r.speakers.length,0);
  const got=S.records.reduce((a,r)=>a+r.speakers.filter(sp=>{
    const v=S.labels.speakers?.[key(r.slug,sp.label)]; return v&&(v.name||v.mixed);}).length,0);
  document.getElementById("progress").textContent=`Размечено ${got} из ${tot} кластеров`;
  // «Ася» и «Анна» разойдутся в анализе как два человека — пусть опечатка видна сразу
  const used=[...new Set(Object.values(S.labels.speakers||{}).map(v=>v.name).filter(Boolean))];
  document.getElementById("names").textContent=
    used.length?`Имена: ${used.sort().join(", ")}`:"";
}
function render(){
  S.labels.speakers ||= {}; S.labels.channels ||= {};
  for(const k in S.labels.speakers){const n=S.labels.speakers[k].name; if(n)names.add(n);}
  const app=document.getElementById("app"); app.innerHTML="";
  const dl=document.createElement("datalist"); dl.id="names";
  [...names].sort().forEach(n=>{const o=document.createElement("option");o.value=n;dl.append(o)});
  app.append(dl);
  for(const r of S.records){
    const box=document.createElement("div"); box.className="file";
    const ch=S.labels.channels[r.slug] ?? S.guess[r.slug] ?? "";
    box.innerHTML=`<div class="fhead"><span class="fname">${r.name||r.slug}</span>
      <span class="meta">${Math.round(r.duration/60)} мин · ${r.src_sr||"?"} Гц ·
      ${r.src_channels===2?"стерео":"моно"} · ${r.speakers.length} кластеров</span>
      <select data-slug="${r.slug}">
        <option value="">— канал? —</option>
        <option value="phone"${ch==="phone"?" selected":""}>телефон</option>
        <option value="vks"${ch==="vks"?" selected":""}>ВКС</option>
        <option value="other"${ch==="other"?" selected":""}>другое</option>
      </select></div>`;
    box.querySelector("select").onchange=e=>{
      S.labels.channels[r.slug]=e.target.value; save();};
    for(const sp of [...r.speakers].sort((a,b)=>b.speech_sec-a.speech_sec)){
      const v=S.labels.speakers[key(r.slug,sp.label)] ||= {name:"",mixed:false};
      const row=document.createElement("div"); row.className="spk";
      const audios=sp.clips.map(c=>
        `<audio controls preload="none" src="/clips/${encodeURIComponent(r.slug)}/${c.file}"></audio>`
      ).join("");
      row.innerHTML=`<span class="lab">${sp.label}</span>
        <span class="dur">${Math.round(sp.speech_sec)} c речи</span>${audios}
        <input type="text" list="names" placeholder="кто это" value="${v.name||""}">
        <button class="me">я</button><button class="mix${v.mixed?" on":""}">смесь</button>`;
      const inp=row.querySelector("input"), mix=row.querySelector(".mix");
      const sync=()=>{row.classList.toggle("done",!!(v.name||v.mixed));};
      inp.onchange=()=>{v.name=inp.value.trim(); if(v.name)names.add(v.name); sync(); save();};
      row.querySelector(".me").onclick=()=>{v.name="я";inp.value="я";names.add("я");sync();save();};
      mix.onclick=()=>{v.mixed=!v.mixed;mix.classList.toggle("on",v.mixed);sync();save();};
      sync(); box.append(row);
    }
    app.append(box);
  }
  progress();
}
fetch("/api/state").then(r=>r.json()).then(s=>{S=s;render()});
</script>"""


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        from urllib.parse import unquote
        path = unquote(self.path.split("?")[0])
        if path == "/":
            return self._send(200, PAGE.encode("utf-8"), "text/html; charset=utf-8")
        if path == "/api/state":
            body = json.dumps(load_state(), ensure_ascii=False).encode("utf-8")
            return self._send(200, body, "application/json; charset=utf-8")
        m = re.fullmatch(r"/clips/([^/]+)/([A-Za-z0-9_.-]+\.wav)", path)
        if m:
            f = (OUT / "clips" / m.group(1) / m.group(2)).resolve()
            if f.is_file() and str(f).startswith(str((OUT / "clips").resolve())):
                return self._send(200, f.read_bytes(), "audio/wav")
        self._send(404, b"not found", "text/plain")

    def do_POST(self):
        if self.path != "/api/labels":
            return self._send(404, b"not found", "text/plain")
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        tmp = LABELS.with_suffix(".json.tmp")
        tmp.write_bytes(raw)
        tmp.replace(LABELS)   # атомарно: разметка не должна побиться на середине записи
        self._send(200, b'{"ok":true}', "application/json")

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    LABELS.parent.mkdir(parents=True, exist_ok=True)
    print(f"разметка: http://127.0.0.1:{PORT}/   (Ctrl-C — выход)")
    print(f"пишется в {LABELS}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
