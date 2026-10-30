// The «Загрузки» window: queue and history. The main window owns the data and sends snapshots.
(() => {
  const tauri = window.__TAURI__;
  let snap = { running: [], waiting: [], finished: [], history: [] };
  let tab = 'queue', collapsed = new Set(), confirming = false, tabPicked = false;
  const content = document.getElementById('content'), foot = document.getElementById('foot');

  const cover = (u) => (u ? `style="background-image:url('${esc(u)}')"` : 'style="background-image:url(\'CardPlaceholder.png\')"');
  const titleRow = (t) => `<div class="title-row"><img src="logo.png" alt=""><div class="t">${t}</div></div>`;

  function card(c, actions, progress, icon, status) {
    return `<div class="card-dl" ${cover(c.thumb)}><div class="top"><div class="names"><div class="name">${esc(c.title)}</div><div class="sub">${esc(c.sub)}</div></div><div class="acts">${actions}</div></div>
      ${progress == null ? '' : `<div class="pbar"><i style="width:${Math.round(Math.min(1, Math.max(0, progress)) * 100)}%"></i></div>`}
      <div class="stat"><span>${icon}</span><span>${esc(status)}</span></div></div>`;
  }
  const btn = (label, act, id, dis) => `<button class="cbtn" data-act="${act}" data-id="${esc(id || '')}" ${dis ? 'disabled' : ''}>${label}</button>`;

  function queueView() {
    const { running, waiting, finished } = snap;
    let h = titleRow('Очередь загрузок');
    if (!running.length && !waiting.length) h += '<div class="empty">Очередь пуста</div>';
    running.forEach(r => {
      h += card({ title: r.title, sub: r.sub, thumb: r.thumb },
        (r.paused ? btn('Продолжить', 'resume', r.id) : btn('Пауза', 'pause', r.id, !r.canPause)) + btn('✕', 'cancel', r.id),
        r.percent, r.paused ? '⏸' : '↓', r.paused ? 'Пауза — нажми «Продолжить»' : r.status);
    });
    waiting.forEach(w => { h += card({ title: w.title, sub: w.sub, thumb: w.thumb }, btn('✕', 'remove', w.id), null, '◷', 'Ждёт очереди'); });
    if (finished.length) {
      h += `<div class="section"><span>Недавно завершённые</span><button data-act="clearFinished">Очистить</button></div>`;
      finished.forEach(f => {
        h += card({ title: f.title, sub: f.sub, thumb: f.thumb },
          (f.file ? btn('Показать файл', 'reveal', f.id) : '') + btn('✕', 'removeFinished', f.id),
          f.ok ? 1 : null, f.ok ? '✓' : '✕', f.note);
      });
    }
    return h;
  }

  const dayStart = (t) => { const d = new Date(t); d.setHours(0, 0, 0, 0); return d.getTime(); };
  function dayTitle(day) {
    const today = dayStart(Date.now()), diff = Math.round((today - day) / 86400000);
    if (diff === 0) return tr('Сегодня'); if (diff === 1) return tr('Вчера');
    const d = new Date(day), opts = { day: 'numeric', month: 'long' };
    if (d.getFullYear() !== new Date().getFullYear()) opts.year = 'numeric';
    return d.toLocaleDateString(locale(), opts);
  }
  function historyView() {
    const items = snap.history;
    let h = titleRow('История скачиваний');
    if (!items.length) return h + '<div class="empty">Пока нет скачиваний</div>';
    const groups = new Map();
    items.slice().sort((a, b) => b.date - a.date).forEach(i => { const k = dayStart(i.date); if (!groups.has(k)) groups.set(k, []); groups.get(k).push(i); });
    const days = [...groups.keys()].sort((a, b) => b - a);
    days.forEach((day, idx) => {
      const list = groups.get(day), shut = collapsed.has(day);
      const allShut = collapsed.size >= days.length;
      h += `<div class="day" data-day="${day}"><span class="chev">${shut ? '▶' : '▼'}</span><span>${dayTitle(day)}</span><span class="n">${list.length}</span>
        ${idx === 0 ? `<span class="all" data-all="1">${allShut ? 'Развернуть все' : 'Свернуть все'}</span>` : ''}</div>`;
      if (list.length > 100) h += '<div class="warnbox">За этот день больше 100 записей. Можно очистить.</div>';
      if (!shut) list.forEach(i => {
        const kind = i.playlistCount != null ? trf('Плейлист · %d видео', i.playlistCount) : (i.audio ? tr('Звук') : tr('Видео'));
        const time = new Date(i.date).toLocaleTimeString(locale(), { hour: '2-digit', minute: '2-digit' });
        const pic = i.thumb || 'HistoryPlaceholder.png';
        h += `<div class="row" data-pick="${esc(i.url)}"><div class="pic" style="background-image:url('${esc(pic)}')"></div><div class="col">
          <div class="meta">${kind} · ${time}</div><div class="ttl">${esc(i.title || i.host || i.url)}</div><div class="lnk">${esc(i.url)}</div></div></div>`;
      });
    });
    return h;
  }

  function render() {
    document.querySelectorAll('#tabs .seg').forEach(b => b.classList.toggle('on', b.dataset.tab === tab));
    content.innerHTML = tab === 'queue' ? queueView() : historyView();
    const busy = snap.running.length || snap.waiting.length;
    const canPauseAll = snap.running.some(r => !r.paused && r.canPause), hasPaused = snap.running.some(r => r.paused);
    if (tab === 'queue') {
      foot.innerHTML = `${canPauseAll ? '<button class="soft" data-act="pauseAll">Остановить все</button>' : hasPaused ? '<button class="soft" data-act="resumeAll">Продолжить все</button>' : ''}
        ${busy ? '<button class="soft" data-act="cancelAll">Удалить все</button>' : ''}<span class="grow"></span><button class="pill" data-act="close">Закрыть</button>`;
    } else {
      foot.innerHTML = `<button class="dangerlink" data-act="askClear" ${snap.history.length ? '' : 'disabled'}>Очистить историю</button><span class="grow"></span><button class="pill" data-act="close">Закрыть</button>`;
    }
    document.getElementById('modal').innerHTML = confirming ? `<div class="modal-bg"><div class="modal"><div class="mt">Очистить историю?</div>
      <div class="mm">Список будет удалён. Скачанные файлы не затрагиваются.</div>
      <div class="mb"><button class="soft" data-act="no">Отмена</button><button class="pill" data-act="yes">Очистить</button></div></div></div>` : '';
  }

  document.getElementById('tabs').addEventListener('click', (e) => { const b = e.target.closest('.seg'); if (b) { tab = b.dataset.tab; tabPicked = true; render(); } });
  document.addEventListener('click', (e) => {
    const day = e.target.closest('[data-day]'), all = e.target.closest('[data-all]'), pick = e.target.closest('[data-pick]'), b = e.target.closest('[data-act]');
    if (all) { const days = [...document.querySelectorAll('[data-day]')].map(x => +x.dataset.day); collapsed = collapsed.size >= days.length ? new Set() : new Set(days); render(); return; }
    if (day && !b) { const k = +day.dataset.day; collapsed.has(k) ? collapsed.delete(k) : collapsed.add(k); render(); return; }
    if (b) {
      const act = b.dataset.act, id = b.dataset.id;
      if (act === 'close') return closeMe();
      if (act === 'askClear') { confirming = true; return render(); }
      if (act === 'no') { confirming = false; return render(); }
      if (act === 'yes') { confirming = false; cmd('clearHistory'); return; }
      if (act === 'reveal') { const f = snap.finished.find(x => x.id === id); if (f && f.file) tauri.core.invoke('reveal', { path: f.file }); return; }
      cmd(act, { id }); return;
    }
    if (pick) { cmd('pick', { url: pick.dataset.pick }); closeMe(); }
  });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeMe(); });

  tauri.event.listen('snapshot', (e) => {
    snap = e.payload;
    if (!tabPicked && !window.__tabInit) { window.__tabInit = true; tab = (snap.running.length || snap.waiting.length || snap.finished.length) ? 'queue' : 'history'; if (snap.openTab) tab = snap.openTab; }
    render();
  });
  window.addEventListener('langchange', () => render());
  tauri.event.listen('open-tab', (e) => { tab = e.payload; tabPicked = true; render(); });
  // Copying a new link means the next move is «Скачать» in the main window, which this one covers — so it steps aside.
  const looksLikeLink = (t) => { if (!t || /\s/.test(t)) return false; try { const u = new URL(/^https?:\/\//i.test(t) ? t : 'https://' + t); return /\.[a-z]{2,}$/i.test(u.hostname); } catch (e) { return false; } };
  let clipAtOpen = null;
  const readClip = async () => { try { return ((await tauri.clipboardManager.readText()) || '').trim(); } catch (e) { return null; } };
  readClip().then(c => { clipAtOpen = c; });
  window.addEventListener('focus', async () => { const c = await readClip(); if (clipAtOpen !== null && c !== null && c !== clipAtOpen && looksLikeLink(c)) closeMe(); });
  render();
  cmd('sync');
})();
