/* Tweak Gezgini: tweaks.json'u listeler, filtreler, ayrıntıları gösterir */
(() => {
  'use strict';
  const { $, $$, esc, tr } = window.HT;
  const RS = { explorer: 'GEZGİN YENİLENİR', oturum: 'OTURUM KAPAT-AÇ', pc: 'YENİDEN BAŞLAT' };
  let T, cat = 'hepsi';
  const detail = (t) => {
    const l = [`# kimlik: ${t.id}`];
    (t.registry || []).forEach((e) => l.push(`${e.path}\n  ${e.name} = ${e.value}   (${e.type}, varsayılan: ${e.original})`));
    (t.services || []).forEach((s) => l.push(`Servis ${s.name}: ${s.original} → ${s.startup}`));
    (t.tasks || []).forEach((k) => l.push(`Zamanlanmış görev devre dışı: ${k}`));
    (t.script || []).forEach((x) => l.push(`PS> ${x}`));
    if (t.undo) l.push('', '# Geri alma', ...t.undo.map((x) => `PS> ${x}`));
    return l.join('\n');
  };
  const render = () => {
    const q = tr($('#tq').value.trim());
    const cats = Object.fromEntries(T.categories.map((c) => [c.id, c.name]));
    const list = T.tweaks.filter((t) => {
      if (cat === 'onerilen' || cat === 'oyuncu') { if (!(t.preset || []).includes(cat)) return false; }
      else if (cat !== 'hepsi' && t.cat !== cat) return false;
      return !q || tr(`${t.name} ${t.desc} ${cats[t.cat]} ${t.id}`).includes(q);
    });
    $('#tcount').textContent = `${list.length} / ${T.tweaks.length} tweak`;
    $('#tlist').innerHTML = list.length ? list.map((t) => `
      <details id="${t.id}">
        <summary>
          <span class="nm">${esc(t.name)}
            ${t.cat === 'arayuz' ? '<span class="tag pref">TERCİH</span>' : ''}
            ${(t.preset || []).includes('onerilen') ? '<span class="tag rec">ÖNERİLEN</span>' : ''}
            ${(t.preset || []).includes('oyuncu') ? '<span class="tag game">OYUNCU</span>' : ''}
            ${t.risk === 'orta' ? '<span class="tag mid">ORTA RİSK</span>' : ''}
            ${RS[t.restart] ? `<span class="tag rs">${RS[t.restart]}</span>` : ''}
          </span>
          <span class="ct">${esc(cats[t.cat])}</span>
          <span class="ds">${esc(t.desc)}</span>
        </summary>
        <div class="det"><pre>${esc(detail(t))}</pre></div>
      </details>`).join('') : '<div style="padding:24px;color:var(--dim)">Eşleşen tweak yok.</div>';
  };
  const chips = () => {
    const all = [['hepsi', 'Hepsi'], ['onerilen', 'Önerilen'], ['oyuncu', 'Oyuncu'], ...T.categories.map((c) => [c.id, c.name])];
    $('#tchips').innerHTML = all.map(([id, n]) => `<button class="chip" data-c="${id}" aria-pressed="${id === cat}">${esc(n)}</button>`).join('');
    $$('#tchips .chip').forEach((b) => b.addEventListener('click', () => { cat = b.dataset.c; chips(); render(); }));
  };
  $('#tq').addEventListener('input', render);
  fetch('/data/tweaks.json').then((r) => r.json()).then((d) => {
    T = d; chips(); render();
    const h = decodeURIComponent(location.hash.slice(1));
    if (h) { const el = document.getElementById(h); if (el) { el.open = true; setTimeout(() => el.scrollIntoView({ block: 'center' }), 50); } }
  });
})();
