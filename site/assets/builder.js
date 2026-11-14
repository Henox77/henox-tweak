/* Yapılandırma Oluşturucu: seçimden henox-ayarlarim.json üretir */
(() => {
  'use strict';
  const { $, $$, esc, copy } = window.HT;
  let T, A, V;
  const CMD = '& ([scriptblock]::Create((irm tweak.henox.dev/run))) -Config "$env:USERPROFILE\\Downloads\\henox-ayarlarim.json" -Run';
  const group = (title, id, items) => `
    <div class="bgroup"><h3>${esc(title)}<button data-all="${id}">Tümünü seç</button></h3>
      <div class="bgrid" id="${id}">${items.map((x) => `<label title="${esc(x.desc || '')}"><input type="checkbox" data-kind="${x.kind}" value="${esc(x.id)}"><span>${esc(x.name)}</span></label>`).join('')}</div>
    </div>`;
  const state = () => ({
    henoxTweak: V,
    tweaks: $$('input[data-kind="t"]:checked').map((i) => i.value),
    apps: $$('input[data-kind="a"]:checked').map((i) => i.value),
  });
  const update = () => {
    const s = state();
    $('#bcount').textContent = `${s.tweaks.length} tweak · ${s.apps.length} uygulama`;
    $('#bjson').textContent = JSON.stringify(s, null, 2);
  };
  Promise.all([fetch('/data/tweaks.json').then((r) => r.json()), fetch('/data/apps.json').then((r) => r.json()), fetch('/data/meta.json').then((r) => r.json())]).then(([t, a, m]) => {
    T = t; A = a; V = m.version;
    let html = '';
    for (const c of T.categories) {
      const items = T.tweaks.filter((x) => x.cat === c.id).map((x) => ({ id: x.id, name: x.name + (x.risk === 'orta' ? ' ⚠' : ''), desc: x.desc, kind: 't' }));
      html += group(`Tweak · ${c.name}`, `g-${c.id}`, items);
    }
    for (const c of A.categories) {
      const items = A.apps.filter((x) => x.cat === c).map((x) => ({ id: x.id, name: x.name, desc: x.desc, kind: 'a' }));
      if (items.length) html += group(`Uygulama · ${c}`, `g-a-${c}`, items);
    }
    $('#bmain').innerHTML = html;
    $('#bmain').addEventListener('change', update);
    $$('[data-all]').forEach((b) => b.addEventListener('click', () => {
      const box = $(`#${CSS.escape(b.dataset.all)}`); const ins = $$('input', box); const on = ins.some((i) => !i.checked);
      ins.forEach((i) => (i.checked = on)); b.textContent = on ? 'Hiçbirini seçme' : 'Tümünü seç'; update();
    }));
    $$('[data-preset]').forEach((b) => b.addEventListener('click', () => {
      const p = b.dataset.preset;
      $$('input[data-kind="t"]').forEach((i) => { const tw = T.tweaks.find((x) => x.id === i.value); i.checked = p !== 'none' && (tw.preset || []).includes(p); });
      if (p === 'none') $$('input[data-kind="a"]').forEach((i) => (i.checked = false));
      update();
    }));
    update();
  });
  $('#bcmd').textContent = CMD;
  $('#bcopy').addEventListener('click', (e) => copy(CMD, e.currentTarget));
  $('#bdl').addEventListener('click', () => {
    const blob = new Blob([JSON.stringify(state(), null, 2)], { type: 'application/json' });
    const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = 'henox-ayarlarim.json'; a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 2000);
    window.HT.toast('İndirildi. Şimdi komutu Yönetici PowerShell\'de çalıştır.');
  });
})();
