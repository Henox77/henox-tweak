/* henox/tweak — ortak site betiği (bağımlılık yok) */
(() => {
  'use strict';
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const tr = (s) => String(s).toLocaleLowerCase('tr');
  const store = { get(k) { try { return localStorage.getItem(k); } catch { return null; } }, set(k, v) { try { localStorage.setItem(k, v); } catch {} } };
  window.HT = { $, $$, esc, tr };

  // ---- Bildirim
  const toast = (m) => { const t = $('#toast'); if (!t) return; t.textContent = m; t.classList.add('on'); clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove('on'), 2600); };
  window.HT.toast = toast;

  // ---- Tema
  $$('[data-theme-toggle]').forEach((b) => b.addEventListener('click', () => {
    const next = document.documentElement.dataset.theme === 'light' ? 'dark' : 'light';
    document.documentElement.dataset.theme = next; store.set('ht-theme', next);
  }));

  // ---- Açılır menüler
  $$('.dd').forEach((dd) => {
    const b = dd.querySelector('button');
    let t;
    const open = (v) => { dd.classList.toggle('open', v); b.setAttribute('aria-expanded', v); };
    b.addEventListener('click', (e) => { e.stopPropagation(); const v = !dd.classList.contains('open'); $$('.dd.open').forEach((x) => x !== dd && x.classList.remove('open')); open(v); });
    dd.addEventListener('mouseenter', () => { clearTimeout(t); if (matchMedia('(hover:hover)').matches) { $$('.dd.open').forEach((x) => x !== dd && x.classList.remove('open')); open(true); } });
    dd.addEventListener('mouseleave', () => { t = setTimeout(() => open(false), 160); });
  });
  document.addEventListener('click', () => $$('.dd.open').forEach((x) => x.classList.remove('open')));

  // ---- Mobil kenar menüsü (dokümantasyon)
  $$('[data-menu]').forEach((b) => b.addEventListener('click', (e) => { e.stopPropagation(); document.body.classList.toggle('side-open'); }));
  document.addEventListener('click', (e) => { if (document.body.classList.contains('side-open') && !e.target.closest('.side')) document.body.classList.remove('side-open'); });

  // ---- Kopyala
  const copy = async (txt, btn) => {
    try { await navigator.clipboard.writeText(txt); }
    catch { const ta = document.createElement('textarea'); ta.value = txt; document.body.appendChild(ta); ta.select(); document.execCommand('copy'); ta.remove(); }
    if (btn) { const s = btn.querySelector('span'); const old = s ? s.textContent : ''; btn.classList.add('done'); if (s) s.textContent = 'Kopyalandı'; setTimeout(() => { btn.classList.remove('done'); if (s) s.textContent = old; }, 1800); }
    toast('Kopyalandı. Terminal (Yönetici) aç ve yapıştır.');
  };
  window.HT.copy = copy;
  document.addEventListener('click', (e) => { const b = e.target.closest('[data-copy]'); if (b) copy(b.dataset.copy, b); });
  // Dokümantasyondaki kod bloklarına kopyala düğmesi
  $$('.prose pre').forEach((pre) => {
    const b = document.createElement('button'); b.className = 'copy-btn'; b.innerHTML = '<svg><use href="#i-copy"/></svg><span>Kopyala</span>';
    b.addEventListener('click', () => copy(pre.innerText.replace(/Kopyala(ndı)?$/, '').trim(), b)); pre.appendChild(b);
  });

  // ---- Yukarı çık
  const top = $('[data-top]');
  if (top) { top.addEventListener('click', () => scrollTo({ top: 0, behavior: 'smooth' })); addEventListener('scroll', () => top.classList.toggle('on', scrollY > 700), { passive: true }); }

  // ---- Kaydırınca belirme
  const io = new IntersectionObserver((es) => es.forEach((e) => { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } }), { rootMargin: '0px 0px -8% 0px' });
  $$('.rv').forEach((el, i) => { el.style.transitionDelay = `${(+el.dataset.d || 0) * 70}ms`; io.observe(el); });

  // ---- Kartlarda imleci takip eden ışık
  $$('.card').forEach((c) => c.addEventListener('pointermove', (e) => { const r = c.getBoundingClientRect(); c.style.setProperty('--mx', `${e.clientX - r.left}px`); c.style.setProperty('--my', `${e.clientY - r.top}px`); }));

  // ---- Sayaçlar
  const cio = new IntersectionObserver((es) => es.forEach((e) => {
    if (!e.isIntersecting) return; cio.unobserve(e.target);
    const el = e.target, to = +el.dataset.count, t0 = performance.now(), dur = 1400;
    const step = (t) => { const p = Math.min(1, (t - t0) / dur); el.textContent = Math.round(to * (1 - Math.pow(1 - p, 4))); if (p < 1) requestAnimationFrame(step); };
    requestAnimationFrame(step);
  }), { threshold: .6 });
  $$('[data-count]').forEach((el) => cio.observe(el));

  // ---- Koyu / açık bölmeli ekran görüntüsü (sürükle veya kendiliğinden salınır)
  const split = $('.split');
  if (split) {
    let user = false, raf;
    const set = (v) => split.style.setProperty('--s', `${Math.max(-12, Math.min(112, v))}%`);
    const auto = (t) => { if (!user) set(50 + Math.sin(t / 2200) * 22); raf = requestAnimationFrame(auto); };
    raf = requestAnimationFrame(auto);
    const move = (e) => { const r = split.getBoundingClientRect(); set(((e.clientX - r.left) / r.width) * 100); };
    split.addEventListener('pointerenter', () => { user = true; });
    split.addEventListener('pointermove', move);
    split.addEventListener('pointerleave', () => { user = false; });
    if (matchMedia('(prefers-reduced-motion: reduce)').matches) { cancelAnimationFrame(raf); set(58); }
  }

  // ---- Yapışkan bölüm sayacı
  const items = $$('.stack .item');
  if (items.length) {
    const num = $('.counter b'), bar = $('.counter .bar i');
    const sio = new IntersectionObserver((es) => es.forEach((e) => {
      if (!e.isIntersecting) return;
      const i = items.indexOf(e.target);
      items.forEach((x, j) => x.classList.toggle('on', j <= i));
      num.textContent = String(i + 1).padStart(2, '0');
      bar.style.width = `${((i + 1) / items.length) * 100}%`;
    }), { rootMargin: '-45% 0px -45% 0px' });
    items.forEach((x) => sio.observe(x));
    items[0].classList.add('on');
  }

  // ---- Galeri sekmeleri
  const tabs = $$('.gallery .tab');
  if (tabs.length) {
    const img = $('.gallery img'), cap = $('.gallery .cap');
    const set = (t) => {
      tabs.forEach((x) => x.setAttribute('aria-selected', x === t));
      img.classList.add('fade');
      setTimeout(() => { img.src = `/img/${t.dataset.img}.png`; img.alt = `Henox Tweak ${t.textContent} ekranı`; }, 160);
      img.onload = () => img.classList.remove('fade');
      cap.textContent = t.dataset.cap;
    };
    tabs.forEach((t) => t.addEventListener('click', () => set(t)));
    cap.textContent = tabs[0].dataset.cap;
    tabs.forEach((t) => { const i = new Image(); i.src = `/img/${t.dataset.img}.png`; });
  }

  // ---- İçindekiler takibi
  const tocLinks = $$('.toc a');
  if (tocLinks.length) {
    const heads = tocLinks.map((a) => document.getElementById(a.hash.slice(1))).filter(Boolean);
    const spy = () => {
      let cur = heads[0];
      for (const h of heads) if (h.getBoundingClientRect().top < 140) cur = h;
      tocLinks.forEach((a) => a.classList.toggle('on', a.hash.slice(1) === cur?.id));
    };
    addEventListener('scroll', spy, { passive: true }); spy();
  }

  // ---- Arama (Ctrl K)
  const sr = $('#sr'), q = $('#srq'), res = $('#srr');
  let index = null, sel = 0, hits = [];
  const loadIndex = () => index || fetch('/data/search.json').then((r) => r.json()).then((d) => (index = d));
  const openS = () => { sr.classList.add('open'); document.body.style.overflow = 'hidden'; q.value = ''; render(); setTimeout(() => q.focus(), 10); loadIndex(); };
  const closeS = () => { sr.classList.remove('open'); document.body.style.overflow = ''; };
  const hl = (s, words) => { let out = esc(s); for (const w of words) if (w) out = out.replace(new RegExp(`(${w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')})`, 'gi'), '<mark>$1</mark>'); return out; };
  const render = async () => {
    const v = tr(q.value.trim());
    if (!v) { res.innerHTML = '<div class="sr-empty">Aramak için yazmaya başla. Örnek: <b>telemetri</b>, <b>discord</b>, <b>geri al</b></div>'; hits = []; return; }
    await loadIndex();
    const words = v.split(/\s+/);
    hits = index.filter((x) => words.every((w) => x.k.includes(w))).slice(0, 40);
    sel = 0;
    if (!hits.length) { res.innerHTML = '<div class="sr-empty">Sonuç bulunamadı.</div>'; return; }
    let last = '', html = '';
    hits.forEach((h, i) => {
      if (h.g !== last) { html += `<div class="g">${esc(h.g)}</div>`; last = h.g; }
      html += `<a href="${h.u}" data-i="${i}" class="${i === 0 ? 'sel' : ''}"><b>${hl(h.t, words)}</b>${h.s ? `<span>${hl(h.s, words)}</span>` : ''}</a>`;
    });
    res.innerHTML = html;
  };
  const move = (d) => { const as = $$('a', res); if (!as.length) return; sel = (sel + d + as.length) % as.length; as.forEach((a, i) => a.classList.toggle('sel', i === sel)); as[sel].scrollIntoView({ block: 'nearest' }); };
  if (sr) {
    $$('[data-search]').forEach((b) => b.addEventListener('click', openS));
    $$('[data-sr-close]').forEach((b) => b.addEventListener('click', closeS));
    q.addEventListener('input', render);
    res.addEventListener('click', (e) => { if (e.target.closest('a')) closeS(); });
    document.addEventListener('keydown', (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); sr.classList.contains('open') ? closeS() : openS(); return; }
      if (e.key === '/' && !sr.classList.contains('open') && !/INPUT|TEXTAREA/.test(document.activeElement.tagName)) { e.preventDefault(); openS(); return; }
      if (!sr.classList.contains('open')) return;
      if (e.key === 'Escape') closeS();
      else if (e.key === 'ArrowDown') { e.preventDefault(); move(1); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); move(-1); }
      else if (e.key === 'Enter') { const a = $$('a', res)[sel]; if (a) { closeS(); location.href = a.href; } }
    });
  }
})();
