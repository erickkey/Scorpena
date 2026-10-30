// Russian / English. Every text is written in Russian; English is looked up by the exact Russian text.
(() => {
  let lang = 'ru'; try { lang = localStorage.getItem('lang') || 'ru'; } catch (e) {}
  window.LANG = () => lang;
  window.tr = (s) => (lang === 'en' && window.EN[s] !== undefined ? window.EN[s] : s);
  window.trf = (f, ...a) => { let i = 0; return tr(f).replace(/%(@|d|s|%)/g, (m, t) => (t === '%' ? '%' : String(a[i++]))); };
  window.locale = () => (lang === 'en' ? 'en-US' : 'ru-RU');
  window.languageChosen = () => { try { return !!localStorage.getItem('lang'); } catch (e) { return true; } };

  const original = new WeakMap();           // text node / element -> its Russian text
  const ATTRS = ['placeholder', 'title', 'aria-label'];
  function node(n) {
    if (n.nodeType === 3) {
      const raw = original.has(n) ? original.get(n) : n.nodeValue, t = raw.trim();
      if (!t) return;
      const en = lang === 'en' ? window.EN[t] : undefined;
      if (en !== undefined) { original.set(n, raw); n.nodeValue = raw.replace(t, en); }
      else if (original.has(n)) { n.nodeValue = original.get(n); original.delete(n); }
    } else if (n.nodeType === 1) {
      for (const a of ATTRS) {
        if (!n.hasAttribute(a)) continue;
        const key = '__ru_' + a, raw = n[key] !== undefined ? n[key] : n.getAttribute(a), en = lang === 'en' ? window.EN[raw] : undefined;
        if (en !== undefined) { n[key] = raw; n.setAttribute(a, en); } else if (n[key] !== undefined) { n.setAttribute(a, n[key]); delete n[key]; }
      }
      n.childNodes.forEach(node);
    }
  }
  const run = (root) => { observer.disconnect(); node(root); observer.observe(document.documentElement, { childList: true, subtree: true }); };
  const observer = new MutationObserver((muts) => { observer.disconnect(); muts.forEach(m => m.addedNodes.forEach(node)); observer.observe(document.documentElement, { childList: true, subtree: true }); });

  function retitle() { const t = document.querySelector('title'); if (t) { if (t.__ru === undefined) t.__ru = t.textContent; t.textContent = tr(t.__ru); } }
  window.setLanguage = (l) => { lang = l; try { localStorage.setItem('lang', l); } catch (e) {} apply(); };
  function apply() { run(document.documentElement); retitle(); document.documentElement.lang = lang; window.dispatchEvent(new Event('langchange')); }
  window.addEventListener('storage', (e) => { if (e.key === 'lang') { lang = e.newValue || 'ru'; apply(); } });
  document.addEventListener('DOMContentLoaded', () => { run(document.documentElement); retitle(); document.documentElement.lang = lang; });
  window.applyTranslation = () => run(document.documentElement);
})();
