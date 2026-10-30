// Shared by every window: the theme, and the way windows talk to the main one.
(() => {
  const root = document.documentElement;
  const apply = () => { let t = null; try { t = localStorage.getItem('theme'); } catch (e) {} root.dataset.theme = t || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'); };
  apply();
  window.addEventListener('storage', (e) => { if (e.key === 'theme') apply(); });
  window.esc = (s) => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  window.cmd = (type, data) => window.__TAURI__.event.emit('cmd', Object.assign({ type }, data || {}));
  // Windows has no flag emoji (it shows «RU» / «US» letters), so the flags are drawn
  window.FLAGS = {
    ru: '<svg class="flagimg" viewBox="0 0 3 2" width="24" height="16"><rect width="3" height="2" fill="#fff"/><rect y="0.667" width="3" height="0.667" fill="#0039a6"/><rect y="1.333" width="3" height="0.667" fill="#d52b1e"/></svg>',
    en: '<svg class="flagimg" viewBox="0 0 28 16" width="24" height="16"><rect width="28" height="16" fill="#fff"/><g fill="#b22234"><rect width="28" height="1.23"/><rect y="2.46" width="28" height="1.23"/><rect y="4.92" width="28" height="1.23"/><rect y="7.38" width="28" height="1.23"/><rect y="9.85" width="28" height="1.23"/><rect y="12.3" width="28" height="1.23"/><rect y="14.77" width="28" height="1.23"/></g><rect width="11.2" height="8.6" fill="#3c3b6e"/></svg>',
  };
  window.closeMe = () => window.__TAURI__.window.getCurrentWindow().close();
})();
