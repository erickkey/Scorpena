// Shared by every window: the theme, and the way windows talk to the main one.
(() => {
  const root = document.documentElement;
  const apply = () => { let t = null; try { t = localStorage.getItem('theme'); } catch (e) {} root.dataset.theme = t || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'); };
  apply();
  window.addEventListener('storage', (e) => { if (e.key === 'theme') apply(); });
  window.esc = (s) => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  window.cmd = (type, data) => window.__TAURI__.event.emit('cmd', Object.assign({ type }, data || {}));
  window.closeMe = () => window.__TAURI__.window.getCurrentWindow().close();
})();
