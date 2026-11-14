// Henox Tweak derleyici: src/ altındaki veriyi tek dosyalık henox.ps1'e gömer ve siteyi public/ klasörüne hazırlar.
// Kullanım:  node build.mjs
import { readFileSync, writeFileSync, mkdirSync, rmSync, cpSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';

const pkg = JSON.parse(readFileSync('package.json', 'utf8'));
const VERSION = pkg.version;
const read = (p) => readFileSync(p, 'utf8').replace(/^﻿/, '');

const tweaks = JSON.parse(read('src/tweaks.json'));
const apps = JSON.parse(read('src/apps.json'));
const debloat = JSON.parse(read('src/debloat.json'));

// --- Doğrulama: aynı id iki kez olmasın, kategoriler tanımlı olsun
const ids = new Set();
for (const t of tweaks.tweaks) {
  if (ids.has(t.id)) throw new Error(`Tekrarlanan tweak id: ${t.id}`);
  ids.add(t.id);
  if (!tweaks.categories.some((c) => c.id === t.cat)) throw new Error(`Bilinmeyen kategori: ${t.cat} (${t.id})`);
  if (!['dusuk', 'orta', 'yuksek'].includes(t.risk)) throw new Error(`Geçersiz risk: ${t.id}`);
  if ((t.script && !t.undo) || (!t.script && t.undo)) throw new Error(`script ve undo birlikte olmalı: ${t.id}`);
}
for (const a of apps.apps) if (!apps.categories.includes(a.cat)) throw new Error(`Bilinmeyen uygulama kategorisi: ${a.cat}`);

// --- PowerShell scriptini oluştur (JSON içinde '@ satır başı olmamalı: here-string'i kapatır)
const embed = (o) => {
  const s = JSON.stringify(o, null, 1);
  if (/^'@/m.test(s)) throw new Error("JSON içinde satır başında '@ olamaz");
  return s;
};
const core = read('src/core.ps1');
const xaml = read('src/window.xaml');
for (const [name, s] of [['core.ps1', core], ['window.xaml', xaml]]) if (/^'@/m.test(s)) throw new Error(`${name} içinde satır başında '@ olamaz`);
let ps = read('src/app.ps1')
  .replace('__VERSION__', VERSION)
  .replace('__TWEAKS_JSON__', () => embed(tweaks))
  .replace('__APPS_JSON__', () => embed(apps))
  .replace('__DEBLOAT_JSON__', () => embed(debloat))
  .replace('__CORE__', () => core.trimEnd())
  .replace('__XAML__', () => xaml.trimEnd());
if (/__[A-Z_]+__/.test(ps)) throw new Error('Doldurulmamış yer tutucu kaldı');
ps = ps.replace(/\r?\n/g, '\r\n');

rmSync('public', { recursive: true, force: true });
mkdirSync('public/data', { recursive: true });

// İki kopya, içerik aynı:
//  run.ps1   → BOM'suz. `irm tweak.henox.dev/run | iex` bunu alır (BOM, Invoke-Expression'ı bozar).
//  henox.ps1 → BOM'lu. İndirilip -File / "PowerShell ile çalıştır" ile açıldığında PS 5.1 Türkçe karakterleri doğru okur.
const runBytes = Buffer.from(ps, 'utf8');
const fileBytes = Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), runBytes]);
writeFileSync('public/run.ps1', runBytes);
writeFileSync('public/henox.ps1', fileBytes);
const hash = (b) => createHash('sha256').update(b).digest('hex').toUpperCase();
const sha256 = hash(runBytes);
writeFileSync('public/SHA256SUMS.txt', `${sha256}  run  (irm tweak.henox.dev/run)\n${hash(fileBytes)}  henox.ps1\n`);

// --- Site
cpSync('site/assets', 'public/assets', { recursive: true });
cpSync('site/img', 'public/img', { recursive: true });
writeFileSync('public/data/tweaks.json', JSON.stringify(tweaks));
writeFileSync('public/data/apps.json', JSON.stringify(apps));
writeFileSync('public/data/debloat.json', JSON.stringify(debloat));
const meta = { version: VERSION, sha256, built: new Date().toISOString(), tweaks: tweaks.tweaks.length, apps: apps.apps.length, debloat: debloat.apps.length };
writeFileSync('public/data/meta.json', JSON.stringify(meta));

const fill = (s) => { for (const [k, v] of Object.entries(meta)) s = s.replaceAll(`{{${k}}}`, String(v)); return s; };
const escAttr = (s) => String(s).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
const stripTags = (s) => s.replace(/<[^>]+>/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/\s+/g, ' ').trim();
const slugify = (s) => stripTags(s).toLocaleLowerCase('tr').replace(/[çğıöşüâî]/g, (c) => ({ ç: 'c', ğ: 'g', ı: 'i', ö: 'o', ş: 's', ü: 'u', â: 'a', î: 'i' }[c])).replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
const P = { head: read('site/partials/head.html'), header: read('site/partials/header.html'), footer: read('site/partials/footer.html') };
const page = (body, { title, desc, path }) => fill(body
  .replace('{{head}}', P.head.replace(/\{\{pageTitle\}\}/g, escAttr(title)).replace(/\{\{pageDesc\}\}/g, escAttr(desc)).replace(/\{\{pagePath\}\}/g, path))
  .replace('{{header}}', P.header).replace('{{footer}}', P.footer));
const outPage = (path, html) => { const dir = `public${path}`; mkdirSync(dir, { recursive: true }); writeFileSync(`${dir}index.html`, html); };

// Ana sayfa
const marqueeItems = [['i-github', 'Açık kaynak'], ['i-download', 'Kurulum yok'], ['i-lock', 'Telemetri yok'], ['i-eye', 'Uygulamadan önce incele'], ['i-monitor', 'Windows 10 ve 11'], ['i-undo', 'Her şey geri alınabilir'], ['i-globe', 'Tamamen Türkçe'], ['i-shield', 'Defender\'a dokunmaz']];
const marquee = marqueeItems.map(([i, t]) => `<span><svg><use href="#${i}"/></svg>${t}</span>`).join('');
outPage('/', page(read('site/index.html').replaceAll('{{marquee}}', marquee), {
  title: 'Henox Tweak: Türkçe WinUtil alternatifi · Açık kaynak Windows iyileştirme aracı',
  desc: `Türkçe WinUtil alternatifi. Uygulamaları kur, ${meta.tweaks} geri alınabilir tweak uygula, gereksizleri kaldır, sorunları onar. Tek komut: irm tweak.henox.dev/run | iex`,
  path: '/',
}));

// Dokümantasyon sayfaları
const GROUPS = ['Kullanım Rehberi', 'Araçlar', 'Yardım'];
const docs = readdirSync('site/docs').filter((f) => f.endsWith('.html')).map((f) => {
  const raw = read(`site/docs/${f}`);
  const m = raw.match(/^<!--meta\s*(\{[\s\S]*?\})\s*-->/);
  if (!m) throw new Error(`Meta eksik: ${f}`);
  const d = JSON.parse(m[1]);
  return { ...d, file: f, body: fill(raw.slice(m[0].length)) };
}).sort((a, b) => GROUPS.indexOf(a.group) - GROUPS.indexOf(b.group) || a.order - b.order);

const search = [];
docs.forEach((d, i) => {
  // Başlıklara kimlik ve bağlantı ekle, içindekileri çıkar
  const toc = [];
  const body = d.body.replace(/<h([23])>([\s\S]*?)<\/h\1>/g, (_, lvl, inner) => {
    const id = slugify(inner);
    toc.push({ lvl, id, text: stripTags(inner) });
    return `<h${lvl} id="${id}">${inner}<a class="anchor" href="#${id}" aria-label="Bu başlığa bağlantı">#</a></h${lvl}>`;
  });
  const side = GROUPS.map((g) => `<h4>${g}</h4>` + docs.filter((x) => x.group === g).map((x) => `<a href="${x.slug}"${x.slug === d.slug ? ' class="cur" aria-current="page"' : ''}>${x.title}</a>`).join('')).join('');
  const prev = docs[i - 1], next = docs[i + 1];
  const pager = `<nav class="pager">${prev ? `<a class="prev" href="${prev.slug}"><span>Önceki</span><b>${prev.title}</b></a>` : ''}${next ? `<a class="next" href="${next.slug}"><span>Sonraki</span><b>${next.title}</b></a>` : ''}</nav>`;
  const tocHtml = d.toc === false || !toc.length ? '' : `<aside class="toc" aria-label="Bu sayfada"><h4>Bu sayfada</h4><ul><li><a href="#top">Genel</a></li>${toc.map((t) => `<li class="l${t.lvl}"><a href="#${t.id}">${t.text}</a></li>`).join('')}</ul></aside>`;
  const html = `<!doctype html><html lang="tr"><head>{{head}}</head><body>{{header}}
<div class="docs"${d.toc === false ? ' style="grid-template-columns:280px minmax(0,1fr)"' : ''}>
  <nav class="side" aria-label="Dokümantasyon">${side}</nav>
  <main class="content" id="main"${d.toc === false ? ' style="max-width:1180px"' : ''}>
    <span id="top"></span>
    <div class="crumb">${d.group}</div>
    <h1>${d.title}</h1>
    <p class="intro">${d.intro || d.desc}</p>
    <div class="prose">${body}</div>
    <div class="edit"><a href="https://github.com/Henox77/henox-tweak/edit/main/site/docs/${d.file}" target="_blank" rel="noopener"><svg><use href="#i-edit"/></svg>Bu sayfayı GitHub'da düzenle</a></div>
    ${pager}
  </main>
  ${tocHtml}
</div>
{{footer}}${(d.scripts || []).map((s) => `<script src="${s}?v={{version}}" defer></script>`).join('')}</body></html>`;
  outPage(d.slug, page(html, { title: `${d.title} · Henox Tweak`, desc: d.desc, path: d.slug }));
  search.push({ g: d.group, t: d.title, s: d.desc, u: d.slug, k: stripTags(`${d.title} ${d.desc}`).toLocaleLowerCase('tr') });
  // Başlıklar ve paragraf metni ayrı sonuçlar olarak
  const parts = body.split(/<h[23] id="/).slice(1);
  parts.forEach((p) => {
    const id = p.slice(0, p.indexOf('"'));
    const h = toc.find((t) => t.id === id);
    const text = stripTags(p.slice(p.indexOf('>') + 1)).replace(/#\s*/, '');
    search.push({ g: d.title, t: h ? h.text : id, s: text.slice(h ? h.text.length : 0, 140).trim(), u: `${d.slug}#${id}`, k: `${h ? h.text : ''} ${text}`.toLocaleLowerCase('tr') });
  });
});
for (const t of tweaks.tweaks) search.push({ g: 'Tweakler', t: t.name, s: t.desc, u: `/araclar/tweak-gezgini/#${t.id}`, k: `${t.name} ${t.desc} ${t.id}`.toLocaleLowerCase('tr') });
for (const a of apps.apps) search.push({ g: 'Uygulamalar', t: a.name, s: `${a.desc} · ${a.id}`, u: '/rehber/uygulamalar/', k: `${a.name} ${a.desc} ${a.id} ${a.cat}`.toLocaleLowerCase('tr') });
writeFileSync('public/data/search.json', JSON.stringify(search));

// 404
outPage('/404/', page(`<!doctype html><html lang="tr"><head>{{head}}</head><body>{{header}}<main id="main" class="wrap" style="text-align:center;padding:120px 24px"><div class="stat"><b>404</b></div><h1 style="font-size:28px;margin-top:16px">Sayfa bulunamadı</h1><p style="color:var(--mut);margin-top:8px">Aradığın sayfa taşınmış veya hiç var olmamış olabilir.</p><div style="display:flex;gap:10px;justify-content:center;margin-top:26px"><a class="btn btn-pri" href="/">Ana sayfa</a><button class="btn" data-search>Ara</button></div></main>{{footer}}</body></html>`, { title: 'Sayfa bulunamadı · Henox Tweak', desc: 'Sayfa bulunamadı', path: '/404/' }));
writeFileSync('public/404.html', read('public/404/index.html'));
for (const f of readdirSync('public', { recursive: true })) { const p = `public/${f}`; if (p.endsWith('.html') && /\{\{\w+\}\}/.test(read(p))) throw new Error(`Doldurulmamış yer tutucu: ${p} → ${read(p).match(/\{\{\w+\}\}/)[0]}`); }

// --- Netlify: /run → script (düz metin, UTF-8)
writeFileSync('public/_redirects', '/run  /run.ps1  200\n/win  /run.ps1  200\n');
writeFileSync(
  'public/_headers',
  ['/henox.ps1', '/run.ps1', '/run', '/win'].map((p) => `${p}\n  Content-Type: text/plain; charset=utf-8\n  Cache-Control: no-cache\n  X-Content-Type-Options: nosniff\n`).join('') +
    `/*\n  X-Frame-Options: DENY\n  Referrer-Policy: strict-origin-when-cross-origin\n  X-Content-Type-Options: nosniff\n`
);

console.log(`Henox Tweak ${VERSION} derlendi · ${meta.tweaks} tweak · ${meta.apps} uygulama · SHA256 ${sha256.slice(0, 16)}…`);
