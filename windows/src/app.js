// Scorpena for Windows: the download queue and the main window's behaviour.
// Same rules as the Mac version (DownloadQueue.swift / DownloadManager.swift).
(() => {
  const tauri = window.__TAURI__;
  const MAX_PARALLEL = 3;
  const $ = (id) => document.getElementById(id);
  const url = $('url'), go = $('go'), box = $('progress');

  // ---------- storage ----------
  const load = (key, fallback) => { try { const v = localStorage.getItem(key); return v ? JSON.parse(v) : fallback; } catch (e) { return fallback; } };
  const save = (key, value) => { try { localStorage.setItem(key, JSON.stringify(value)); } catch (e) {} };

  const settings = Object.assign({ cookieOrder: [], lastCookie: '', cookiePreflightDone: false, lastToolCheck: 0, muteChime: false, chimeVoice: 'female', muteLaunchSound: false, cleanupReminder: 'weekly', sendDiagnostics: true, lastCleanupCheck: 0, videoFormat: 'mp4', audioFormat: 'mp3', mode: 'video', stripAudio: false, quality: 0, folder: null, limitStep: 9 },
    load('settings', {}));
  const LIMIT_STEPS = [5, 10, 20, 30, 50, 75, 100, 150, 200, 0]; // Mbit/s, 0 = no limit
  const limitKbit = () => (LIMIT_STEPS[settings.limitStep] || 0) * 1000;

  // ---------- state ----------
  let waiting = [];            // queued downloads
  let running = [];            // {item, percent, status, paused, canPause, started}
  let finished = [];                 // «Недавно завершённые» (this session only)
  let history = load('history', []);  // kept between launches, shown by day
  const previews = {};
  let plDone = load('plDone', {});    // playlist id -> videos that came through
  let statusLine = '';                // probe result / progress of reading a playlist               // id -> {title, thumb}
  let batchTotal = 0, batchDone = 0, batchStart = 0;
  let single = { message: '', failed: false, file: null };   // what the main window shows when nothing runs

  const uid = () => (crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random().toString(16).slice(2));
  const busyCount = () => running.length;
  const batchActive = () => batchTotal > 1 && busyCount() + waiting.length > 0;

  function persist() {
    const pending = running.map(r => ({ ...r.item, paused: r.paused })).concat(waiting);
    if (pending.length) save('queue', pending); else { try { localStorage.removeItem('queue'); } catch (e) {} }
    save('settings', settings);
    save('history', history.slice(0, 500));
  }

  // ---------- messages ----------
  const WIN = /Windows/i.test(navigator.userAgent) || localStorage.getItem('forceWin') === '1';
  const AUTH_WIN = 'Для скачивания требуется вход в аккаунт.\n\nСайт отдаёт это видео только авторизованным пользователям. Chrome и Edge не разрешают другим программам читать их куки, поэтому программа не может ими воспользоваться. Есть два выхода:\n\n1. Firefox. Нажми «Открыть в Firefox» и войди в аккаунт на сайте. Потом вернись сюда и нажми «Повторить»: программа увидит вход и скачает видео.\n\n2. Окно входа. Нажми «Войти в окне» и войди на сайт в открывшемся окне. Закрой его, и скачивание начнётся само. Подойдёт, если Firefox не установлен.';
  const AUTH_GOOGLE = 'Если Google не пускает во встроенное окно, войди через Firefox (способ 1).';
  const isGoogleSite = (u) => /(^|\.)(youtube\.com|youtu\.be|google\.com)$/.test(host(u));
  const loginPage = (u) => { const h = host(u);
    if (/(^|\.)(youtube\.com|youtu\.be)$/.test(h)) return 'https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2F';
    if (/instagram\.com$/.test(h)) return 'https://www.instagram.com/accounts/login/';
    if (/vimeo\.com$/.test(h)) return 'https://vimeo.com/log_in';
    return u; };
  const MESSAGES = {
    auth: 'Для скачивания требуется вход в аккаунт:\n\nСайт отдаёт это видео только при входе в аккаунт. Войди на сайт в браузере и повтори. Например, Vimeo сейчас требует вход почти для всех роликов, даже открытых.',
    unavailable: 'Видео недоступно (удалено, приватное или заблокировано в твоём регионе).',
    unsupported: 'Ссылка не распознана или сайт не поддерживается. Нужен прямой адрес страницы видео (YouTube, VK и т.д.).',
    format: 'Не нашёлся формат под выбранное качество — попробуй «Максимальное».',
    forbidden: 'YouTube отклонил загрузку (403). Открой «Дополнительно» → «Проверить сейчас», затем повтори. Или попробуй другую ссылку.',
    network: 'Нет соединения с интернетом. Если включён VPN, попробуй его выключить.',
    disk: 'Не хватает места на диске.',
    other: 'Что-то пошло не так. Попробуй ещё раз или сообщи об ошибке. А пока попробуй другую ссылку.',
  };
  const fmtTitle = (it) => (it.audio ? it.audioFormat : it.videoFormat).toUpperCase().replace('WEBM', 'WebM');
  const elapsed = (ms) => { const t = Math.max(0, Math.floor(ms / 1000)); return t < 60 ? t + ' ' + tr('с') : Math.floor(t / 60) + ':' + String(t % 60).padStart(2, '0'); };
  const formatDuration = (ms) => { const t = Math.round(ms / 1000); return t < 60 ? trf('%d с', t) : trf('%d мин %d с', Math.floor(t / 60), t % 60); };
  const host = (u) => { try { return new URL(u).host.replace(/^www\./, ''); } catch (e) { return u; } };

  // ---------- queue ----------
  function isActive(link, audio) {
    return running.some(r => r.item.url === link && r.item.audio === audio) || waiting.some(i => i.url === link && i.audio === audio);
  }

  function submit(item) {
    if (busyCount() + waiting.length === 0) { batchTotal = 0; batchDone = 0; batchStart = Date.now(); }
    batchTotal += 1;
    waiting.push(item);
    single = { message: '', failed: false, file: null };
    loadPreview(item);
    pump();
  }

  // Title and cover of a link, fetched in the background; the cover is kept as a small picture so the history works offline.
  function loadPreview(item) {
    if (previews[item.id] || !tauri) return;
    previews[item.id] = {};
    tauri.core.invoke('fetch_preview', { url: item.url }).then(async (r) => {
      if (!r) return;
      const [title, remote] = r;
      previews[item.id] = { title, thumb: remote };
      emitSoon();
      if (remote) { const small = await smallPicture(remote); if (small) { previews[item.id].thumb = small; emitSoon(); } }
    }).catch(() => {});
  }
  function smallPicture(src) {
    return new Promise((resolve) => {
      const img = new Image(); img.crossOrigin = 'anonymous';
      img.onload = () => { try { const c = document.createElement('canvas'); c.width = 192; c.height = 108;
        c.getContext('2d').drawImage(img, 0, 0, 192, 108); resolve(c.toDataURL('image/jpeg', 0.7)); } catch (e) { resolve(null); } };
      img.onerror = () => resolve(null); img.src = src;
    });
  }

  function pump() {
    while (running.length < MAX_PARALLEL && waiting.length) {
      const item = waiting.shift();
      const job = { slowSite: /vimeo\./i.test(item.url), item, percent: 0, status: tr('Скачивание сейчас начнётся…'), paused: false, canPause: false, started: Date.now() };
      running.push(job);
      if (item.startPaused) { delete item.startPaused; job.paused = true; job.status = tr('Пауза — нажми «Продолжить»'); }
      else launch(job);
    }
    persist();
    render();
  }

  function launch(job) {
    job.paused = false; job.canPause = false;
    const it = job.item;
    tauri.core.invoke('run_job', { job: { id: it.id, url: it.url, dest: it.dest, maxHeight: it.maxHeight || null,
      audio: it.audio, stripAudio: it.stripAudio, videoFormat: it.videoFormat, audioFormat: it.audioFormat, limitKbit: limitKbit(),
      cookieOrder: settings.cookieOrder || [], lastCookie: settings.lastCookie || '' } })
      .catch(err => finish(it.id, { ok: false, reason: 'other', logTail: String(err) }));
  }

  function pause(id) {
    const job = running.find(r => r.item.id === id);
    if (!job || job.paused || !job.canPause) return;
    tauri.core.invoke('stop_job', { id });
    job.paused = true; job.status = tr('Пауза — нажми «Продолжить»'); persist(); render();
  }
  function resume(id) {
    const job = running.find(r => r.item.id === id);
    if (!job || !job.paused) return;
    job.status = tr('Скачивание сейчас начнётся…'); launch(job); persist(); render();
  }
  function cancel(id) {
    const job = running.find(r => r.item.id === id);
    if (job) { tauri.core.invoke('stop_job', { id }); running = running.filter(r => r.item.id !== id); }
    else waiting = waiting.filter(i => i.id !== id);
    batchTotal = Math.max(0, batchTotal - 1);
    if (running.length === 0) single = { message: job ? tr('Отменено') : '', failed: false, file: null };
    pump();
  }
  const pauseAll = () => running.filter(r => !r.paused && r.canPause).forEach(r => pause(r.item.id));
  const resumeAll = () => running.filter(r => r.paused).forEach(r => resume(r.item.id));

  function finish(id, d) {
    const job = running.find(r => r.item.id === id);
    if (!job) return;
    running = running.filter(r => r.item.id !== id);
    const title = d.name || host(job.item.url);
    if (d.ok && d.cookie !== undefined) { settings.lastCookie = d.cookie; }
    const fileName = d.name || '';
    let okNote = tr('Готово ✅');
    if (d.ok && job.item.audio) okNote = trf('Готово ✅ (%@)', fmtTitle(job.item));
    else if (d.ok && d.note === 'h264') okNote = tr('Готово ✅ (перекодировано в H.264)');
    else if (d.ok && d.note === 'no-ffmpeg') okNote = tr('Готово ✅ (кодек не H.264 — ffmpeg недоступен)');
    else if (d.ok && d.note === 'h264-failed') { d = { ...d, ok: false, reason: 'h264', kept: true }; }
    const authWin = !d.ok && d.reason === 'auth' && WIN;
    const note = authWin ? tr(AUTH_WIN) + (isGoogleSite(job.item.url) ? '\n\n' + tr(AUTH_GOOGLE) : '') : d.ok ? okNote : (d.reason === 'h264' ? trf('Видео скачано (%@), но перекодировать в H.264 не удалось. Файл остался в исходном кодеке.', fileName) : tr(MESSAGES[d.reason] || MESSAGES.other));
    const pv = previews[id] || {};
    const shownTitle = pv.title || d.name || host(job.item.url);
    finished.unshift({ id, title: shownTitle, sub: host(job.item.url) + ' – ' + fmtTitle(job.item), thumb: pv.thumb || '', url: job.item.url, ok: d.ok, note, file: d.file || null });
    const pl = job.item.playlist;
    if (pl) {
      if (d.ok) plDone[pl.id] = (plDone[pl.id] || 0) + 1;
      const left = running.some(r => r.item.playlist && r.item.playlist.id === pl.id) || waiting.some(i => i.playlist && i.playlist.id === pl.id);
      if (!left) {
        if (plDone[pl.id] > 0) {
          history = history.filter(h => !(h.url === pl.listURL && h.playlistCount != null));
          history.unshift({ id: pl.id, url: pl.listURL, title: pl.title || tr('Плейлист'), thumb: pl.thumb || '', audio: false, date: Date.now(), host: host(pl.listURL), playlistCount: plDone[pl.id] });
        }
        delete plDone[pl.id];
      }
      save('plDone', plDone);
    } else if (d.ok) {
      history = history.filter(h => h.url !== job.item.url);
      history.unshift({ id, url: job.item.url, title: shownTitle, thumb: pv.thumb || '', audio: job.item.audio, date: Date.now(), host: host(job.item.url) });
    }
    if (d.ok) { chime(); noteSuccess(); } else if (BREAKAGE[d.reason]) noteFailure(BREAKAGE[d.reason], host(job.item.url), d.logTail);
    if (!d.ok && d.reason === 'auth') { /* counted above */ }
    if (d.ok) batchDone += 1; else batchTotal = Math.max(0, batchTotal - 1);
    if (running.length === 0 && waiting.length === 0) {
      single = d.ok
        ? { message: okNote + ' · ' + formatDuration(Date.now() - job.started), failed: false, file: d.file || null }
        : { message: note, failed: true, file: d.kept ? (d.file || null) : null, log: d.logTail || '', url: job.item.url, reportStatus: 'idle', authWin, item: job.item };
    }
    pump();
  }

  // ---------- events from the engine ----------
  if (tauri) {
    tauri.event.listen('job-progress', (e) => {
      const p = e.payload, job = running.find(r => r.item.id === p.id);
      if (!job || job.paused) return;
      job.percent = Math.min(1, p.percent / 100); job.canPause = true;
      job.status = (job.item.audio ? tr('Скачивание аудио… ') : tr('Скачивание… ')) + Math.round(p.percent) + '%' + (p.speed && p.speed !== 'NA' ? ' · ' + p.speed : '');
      render();
    });
    tauri.event.listen('job-line', (e) => {
      const p = e.payload, job = running.find(r => r.item.id === p.id), l = p.line;
      if (!job || job.paused) return;
      if (l.toLowerCase().startsWith('[vimeo')) job.slowSite = true;
      if (/total fragments/i.test(l)) job.fragmented = true;
      if (l.includes('Retrying') || l.includes('Got error')) job.status = tr('Нет связи — жду и продолжу сам…');
      else if (l.includes('[ExtractAudio]')) { job.canPause = false; job.status = trf('Конвертация в %@…', fmtTitle(job.item)); }
      else if (l.includes('[Merger]')) { job.canPause = false; job.status = tr('Объединение видео и звука…'); }
      else if (/\[(VideoRemuxer|VideoConvertor|Recode)\]/.test(l)) { job.canPause = false; job.status = trf('Упаковка в %@…', fmtTitle(job.item)); }
      else if (l.includes('Destination:')) job.status = job.item.audio ? tr('Скачивание аудио…') : tr('Скачивание…');
      render();
    });
    tauri.event.listen('job-phase', (e) => {
      const p = e.payload, job = running.find(r => r.item.id === p.id);
      if (!job || job.paused) return;
      job.canPause = false;
      if (p.phase === 'check') { job.percent = 1; job.status = tr('Проверка кодека…'); }
      else { job.percent = p.percent; job.status = trf('Перекодирование в H.264… %d%%', Math.round(p.percent * 100)); }
      render();
    });
    tauri.event.listen('job-attempt', (e) => {
      const p = e.payload, job = running.find(r => r.item.id === p.id);
      if (!job || job.paused) return;
      const name = p.line === 'login' ? tr('окна входа') : p.line.charAt(0).toUpperCase() + p.line.slice(1);
      job.status = trf('Нужен вход — пробую %@…', trf('cookies из %@', name)); render();
    });
    tauri.event.listen('job-done', (e) => finish(e.payload.id, e.payload));
    tauri.event.listen('login-closed', () => { if (single.failed && single.authWin) retryFailed(); });
  }

  // ---------- rendering of the main window ----------
  const esc = (s) => String(s).replace(/[&<>]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
  let lastKey = '';
  function render() {
    const first = running[0];
    let html = '';
    if (batchActive()) {
      const partial = running.reduce((n, r) => n + r.percent, 0);
      const fraction = batchTotal ? Math.min(1, (batchDone + partial) / batchTotal) : 0;
      html = `<div class="bar"><i style="width:${fraction * 100}%"></i></div>
        <div class="prow"><span class="txt">${elapsed(Date.now() - batchStart)} · ${trf('Загрузок идёт: %d · в очереди: %d · готово: %d', busyCount(), waiting.length, batchDone)}</span>
        <button class="link" data-act="queue">Открыть очередь</button></div>`;
    } else if (first || single.message) {
      const busy = first && !first.paused && first.percent === 0;
      const pct = first ? first.percent * 100 : (single.failed ? 0 : 100);
      html = `<div class="bar ${busy ? 'busy' : ''}"><i style="width:${pct}%"></i></div>
        <div class="prow"><span class="txt">${esc(first ? first.status : (single.failed ? tr('Ошибка') : single.message))}</span>
          ${first ? (first.paused ? `<button data-act="resume" data-id="${first.item.id}">Продолжить</button>` : `<button data-act="pause" data-id="${first.item.id}" ${first.canPause ? '' : 'disabled'}>Пауза</button>`) : ''}
          <button data-act="cancel" data-id="${first ? first.item.id : ''}" ${first ? '' : 'disabled'}>Отменить</button>
          <button data-act="reveal" ${single.file && !first ? '' : 'disabled'}>Показать файл</button></div>
        ${first && !first.paused ? `<div class="tiny">${Math.floor((Date.now() - first.started) / 1000)} ${tr('с')}</div>` : ''}
        ${first && first.status === tr('Скачивание сейчас начнётся…') ? `<div class="tiny wrap">${esc(tr('Программа запрашивает у сайта данные о видео: адреса потоков и способ обхода защиты. Обычно 2–10 секунд.'))}</div>` : ''}
        ${first && first.fragmented && first.slowSite ? `<div class="tiny wrap">${esc(tr('Сайт отдаёт видео множеством мелких кусков, а не одним файлом — их приходится качать по очереди, поэтому медленнее обычного. У Vimeo почти всегда так.'))}</div>` : ''}
        ${!first && single.failed ? `<div class="err">${esc(single.message)}</div>
          ${single.authWin ? `<div class="prow" style="gap:8px"><button class="soft sm" data-act="firefox">${esc(tr('Открыть в Firefox'))}</button><button class="soft sm" data-act="login">${esc(tr('Войти в окне'))}</button><button class="soft sm" data-act="retry">${esc(tr('Повторить'))}</button></div>` : ''}
          <div class="prow" style="gap:8px"><button class="soft sm" data-act="report" ${single.reportStatus === 'sending' || single.reportStatus === 'sent' ? 'disabled' : ''}>${single.reportStatus === 'sending' ? '…' : esc(tr('Сообщить об ошибке'))}</button>
          ${single.reportStatus === 'sent' ? `<span class="tiny" style="color:var(--green)">${esc(trf('Отправлено (обращение №%@) — спасибо!', single.reportNumber))}</span>` : ''}
          ${single.reportStatus === 'failed' ? `<span class="tiny">${esc(tr('Не удалось отправить — текст скопирован, отправь вручную в Telegram'))}</span>` : ''}</div>` : ''}`;
    }
    if (!html && statusLine) html = `<div class="prow"><span class="txt">${esc(statusLine)}</span></div>`;
    box.classList.toggle('show', !!html);
    if (html !== lastKey) { box.innerHTML = html; lastKey = html; }
    updateGo();
    emitSoon();
  }
  setInterval(() => { if (running.length) render(); }, 500);

  box.addEventListener('click', (e) => {
    const b = e.target.closest('button'); if (!b) return;
    const id = b.dataset.id, act = b.dataset.act;
    if (act === 'pause') pause(id); else if (act === 'resume') resume(id); else if (act === 'cancel') cancel(id);
    else if (act === 'reveal' && single.file) tauri.core.invoke('reveal', { path: single.file });
    else if (act === 'queue') window.dispatchEvent(new CustomEvent('open-downloads'));
    else if (act === 'report') reportError();
    else if (act === 'firefox' && single.url) tauri.core.invoke('open_in_firefox', { url: single.url });
    else if (act === 'login' && single.url) tauri.core.invoke('open_login', { url: loginPage(single.url), title: tr('Вход в аккаунт') });
    else if (act === 'retry') retryFailed();
  });
  function retryFailed() {
    if (!single.failed || !single.item) return;
    const item = { ...single.item, id: uid() };
    submit(item);
  }

  // ---------- the «Загрузки» window ----------
  let emitTimer = null;
  function snapshot(openTab) {
    const card = (it) => { const pv = previews[it.id] || {}; return { title: pv.title || host(it.url), sub: host(it.url) + ' – ' + fmtTitle(it), thumb: pv.thumb || '' }; };
    return {
      openTab,
      running: running.map(r => ({ id: r.item.id, ...card(r.item), percent: r.percent, status: r.status, paused: r.paused, canPause: r.canPause })),
      waiting: waiting.map(i => ({ id: i.id, ...card(i) })),
      finished, history,
    };
  }
  function emitNow(openTab) { if (tauri) tauri.event.emit('snapshot', snapshot(openTab)); }
  function emitSoon() { if (emitTimer) return; emitTimer = setTimeout(() => { emitTimer = null; emitNow(); }, 250); }
  function openDownloads(tab) {
    tauri.core.invoke('open_window', { label: 'downloads', page: 'downloads.html', title: tr('Загрузки'), width: 560, height: 640 });
    setTimeout(() => { emitNow(tab); if (tab) tauri.event.emit('open-tab', tab); }, 400);
  }
  window.addEventListener('open-downloads', () => openDownloads('queue'));
  document.getElementById('btn-downloads').addEventListener('click', () => openDownloads(null));
  if (tauri) tauri.event.listen('cmd', (e) => {
    const c = e.payload;
    switch (c.type) {
      case 'sync': emitNow(); break;
      case 'pause': pause(c.id); break;
      case 'resume': resume(c.id); break;
      case 'cancel': cancel(c.id); break;
      case 'pauseAll': pauseAll(); break;
      case 'resumeAll': resumeAll(); break;
      case 'cancelAll': [...running.map(r => r.item.id), ...waiting.map(i => i.id)].forEach(cancel); break;
      case 'remove': waiting = waiting.filter(i => i.id !== c.id); batchTotal = Math.max(0, batchTotal - 1); pump(); break;
      case 'removeFinished': finished = finished.filter(f => f.id !== c.id); emitNow(); break;
      case 'clearFinished': finished = []; emitNow(); break;
      case 'clearHistory': history = []; persist(); emitNow(); break;
      case 'pick': url.value = c.url; url.dispatchEvent(new Event('input')); url.focus(); break;
    }
  });

  // ---------- the controls ----------
  const modeFromUI = () => document.querySelector('.seg.on').parentElement.dataset.kind;
  document.querySelectorAll('.segs').forEach(group => group.querySelectorAll('.seg').forEach(b => b.addEventListener('click', () => {
    const kind = group.dataset.kind, value = b.textContent.toLowerCase();
    if (kind === 'audio') settings.audioFormat = value; else settings.videoFormat = value;
    settings.mode = kind; persist();
  })));
  // restore the picked format
  document.querySelectorAll('.seg.on').forEach(b => b.classList.remove('on'));
  document.querySelectorAll('.segs').forEach(group => group.querySelectorAll('.seg').forEach(b => {
    const mine = group.dataset.kind === 'audio' ? settings.audioFormat : settings.videoFormat;
    if (settings.mode === group.dataset.kind && b.textContent.toLowerCase() === mine) b.classList.add('on');
  }));

  const noAudio = document.querySelector('.settings input[type=checkbox]');
  noAudio.checked = settings.stripAudio;
  noAudio.addEventListener('change', () => { settings.stripAudio = noAudio.checked; persist(); });
  const folderBtn = document.querySelectorAll('.settings button')[1];
  let folder = settings.folder;
  const folderName = () => (folder || '').split(/[\\/]/).filter(Boolean).pop() || folder || '';
  async function initFolder() {
    if (!folder) folder = await tauri.core.invoke('default_folder');
    folderBtn.textContent = tr('Папка:') + ' ' + folderName(); folderBtn.title = folder;
  }
  folderBtn.addEventListener('click', async () => {
    const picked = await tauri.core.invoke('choose_folder', { start: folder });
    if (picked) { folder = picked; settings.folder = picked; persist(); folderBtn.textContent = tr('Папка:') + ' ' + folderName(); folderBtn.title = picked; }
  });

  const canGo = () => !!window.__plausible && window.__plausible(window.__parse(url.value));
  function updateGo() { go.disabled = !canGo(); }
  url.addEventListener('input', updateGo);

  const hintEl = $('hint');
  let hintTimer = null;
  function flashHint(text) { hintEl.className = 'odd'; hintEl.textContent = text; clearTimeout(hintTimer); hintTimer = setTimeout(() => { hintEl.textContent = ''; }, 5000); }

  // ---------- quality ----------
  const qualityBtn = document.querySelectorAll('.settings button')[0];
  let probe = { heights: [], sizes: {}, busy: false, title: null, forUrl: '' };
  let probeTimer = null;
  const qLabel = (h) => (h === 2160 ? '2160p (4K)' : h === 1440 ? '1440p (2K)' : h + 'p');
  const bytesText = (n) => { const mb = n / 1e6, dec = LANG() === 'en' ? '.' : ','; return mb >= 1000 ? (mb / 1000).toFixed(2).replace('.', dec) + ' ' + tr('ГБ') : Math.round(mb) + ' ' + tr('МБ'); };
  const sizeText = (h) => { const key = h === 0 ? probe.heights[0] : h; const v = probe.sizes[key]; return v ? '≈ ' + bytesText(v) : null; };
  const qMenuLabel = (h) => { const t = sizeText(h); return t ? `${qLabel(h)} — ${t}` : qLabel(h); };
  const maxLabel = () => { if (!probe.heights.length) return tr('Максимально доступное'); const t = sizeText(0); return t ? trf('Максимальное — %@', t) : tr('Максимальное'); };
  function renderQuality() {
    qualityBtn.textContent = probe.busy ? tr('Качество:') + ' …' : tr('Качество:') + ' ' + (settings.quality === 0 ? maxLabel() : qMenuLabel(settings.quality));
  }
  function resetProbe() {
    probe = { heights: [], sizes: {}, busy: false, title: null, forUrl: '' };
    clearInterval(probeTimer); statusLine = ''; setProbeTitle(null); renderQuality(); render();
  }
  function setProbeTitle(t) { const el = $('probe-title'); if (el) el.textContent = t ? '▸ ' + t : ''; }
  async function runProbe() {
    if (probe.busy || !canGo() || probe.heights.length) return;
    const link = window.__parse(url.value).href, start = Date.now();
    probe.busy = true; renderQuality();
    const tick = () => { if (!running.length) { statusLine = trf('Проверяю доступные качества… %d с', Math.floor((Date.now() - start) / 1000)); render(); } };
    tick(); probeTimer = setInterval(tick, 500);
    let r = null;
    try { r = await tauri.core.invoke('probe_quality', { url: link }); } catch (e) {}
    clearInterval(probeTimer);
    if (window.__parse(url.value).href !== link) { probe.busy = false; renderQuality(); return; }   // the link changed meanwhile
    const secs = ((Date.now() - start) / 1000).toFixed(1).replace('.', ',');
    probe.busy = false;
    if (r && r.heights.length) {
      probe = { heights: r.heights, sizes: r.sizes, busy: false, title: r.title, forUrl: link };
      if (settings.quality !== 0 && !r.heights.includes(settings.quality)) settings.quality = 0;
      statusLine = trf('Доступно (%@ с): ', secs) + r.heights.map(h => h + 'p').join(', ');
      setProbeTitle(r.title);
    } else statusLine = trf('Не удалось определить качества за %@ с — при скачивании возьмётся максимум доступное.', secs);
    renderQuality(); render();
  }
  let menu = null;
  function closeMenu() { if (menu) { menu.remove(); menu = null; } }
  qualityBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    if (menu) return closeMenu();
    const items = [{ t: tr('Проверить качество'), dis: !canGo() || probe.busy || probe.heights.length > 0, f: runProbe }, null,
      { t: maxLabel(), on: settings.quality === 0, f: () => { settings.quality = 0; persist(); renderQuality(); } },
      ...probe.heights.map(h => ({ t: qMenuLabel(h), on: settings.quality === h, f: () => { settings.quality = h; persist(); renderQuality(); } }))];
    menu = document.createElement('div'); menu.className = 'menu';
    items.forEach(i => { if (!i) { menu.appendChild(document.createElement('hr')); return; }
      const b = document.createElement('button'); b.textContent = (i.on ? '✓ ' : '') + i.t; b.disabled = !!i.dis;
      b.onclick = () => { closeMenu(); i.f(); }; menu.appendChild(b); });
    document.body.appendChild(menu);
    const r = qualityBtn.getBoundingClientRect();
    menu.style.left = Math.max(8, Math.min(r.left, innerWidth - menu.offsetWidth - 8)) + 'px';
    menu.style.top = (r.top - menu.offsetHeight - 4 > 8 ? r.top - menu.offsetHeight - 4 : r.bottom + 4) + 'px';
  });
  document.addEventListener('click', closeMenu);
  url.addEventListener('input', () => { if (probe.forUrl || probe.busy || statusLine) resetProbe(); });

  // ---------- playlists ----------
  function detectPlaylist(raw) {
    let u; try { u = new URL(/^https?:\/\//i.test(raw.trim()) ? raw.trim() : 'https://' + raw.trim()); } catch (e) { return null; }
    const h = u.hostname.toLowerCase();
    if (!(h.endsWith('youtube.com') || h === 'youtu.be')) return null;
    const list = u.searchParams.get('list');
    if (!list || list.startsWith('RD')) return null;
    const hasVideo = u.searchParams.has('v') || (h === 'youtu.be' && u.pathname.length > 1);
    return { hasVideo, listURL: 'https://www.youtube.com/playlist?list=' + list };
  }
  const folderFor = (title) => { const base = (title || '').replace(/\//g, '-').replace(/:/g, '-').replace(/[\\*?"<>|]/g, '-').trim(); return base ? base.slice(0, 80) : tr('Плейлист'); };
  const joinPath = (a, b) => a.replace(/[\\/]+$/, '') + (a.includes('\\') && !a.includes('/') ? '\\' : '/') + b;
  let playlistBusy = false;
  function flash(text, ms) { statusLine = text; render(); setTimeout(() => { if (statusLine === text) { statusLine = ''; render(); } }, ms || 6000); }

  function dialog({ title, message, buttons }) {
    return new Promise((resolve) => {
      const wrap = document.createElement('div'); wrap.className = 'modal-bg';
      wrap.innerHTML = `<div class="modal wide"><img src="logo.png" alt="" style="width:56px;height:56px;margin:0 auto"><div class="mt">${esc(tr(title))}</div>
        <div class="mm" style="white-space:pre-line">${esc(tr(message))}</div><div class="mb"></div></div>`;
      const mb = wrap.querySelector('.mb');
      buttons.forEach(b => { const el = document.createElement('button'); el.className = b.primary ? 'pill' : 'soft'; el.textContent = tr(b.label);
        el.style.minWidth = '96px'; el.onclick = () => { wrap.remove(); resolve(b.value); }; mb.appendChild(el); });
      document.body.appendChild(wrap);
    });
  }

  async function startPlaylist(list, audio) {
    if (playlistBusy) return; playlistBusy = true;
    statusLine = tr('Читаю плейлист…'); render();
    let r = null;
    try { r = await tauri.core.invoke('fetch_playlist', { listUrl: list.listURL }); } catch (e) {}
    statusLine = ''; playlistBusy = false;
    if (!r) { flash(tr('Нужен вход или плейлиста не существует'), 8000); if (!list.hasVideo) return; }
    let text;
    if (r && list.hasVideo) text = trf('В плейлисте %d видео. Скачать весь плейлист или только это видео?', r.total);
    else if (r) text = trf('В плейлисте %d видео. Скачать их все? Они встанут в очередь загрузок.', r.total);
    else text = tr('Скачать весь плейлист или только это видео?');
    if (r && r.total > r.entries.length) text += '\n\n' + trf('За один раз добавятся первые %d.', r.entries.length);
    const choice = await dialog({ title: 'Это плейлист', message: text, buttons: [
      { label: 'Отмена', value: 'cancel' },
      ...(list.hasVideo ? [{ label: 'Только это видео', value: 'single' }] : []),
      ...(r ? [{ label: 'Весь плейлист', value: 'whole', primary: true }] : []) ] });
    if (choice === 'single') submitCurrent(audio);
    else if (choice === 'whole' && r) enqueuePlaylist(r, list, audio);
    render();
  }

  function enqueuePlaylist(r, list, audio) {
    const dest = joinPath(folder, folderFor(r.title));
    tauri.core.invoke('make_folder', { path: dest });
    const vid = (u) => { try { return new URL(u).searchParams.get('v'); } catch (e) { return null; } };
    const pl = { id: uid(), title: r.title || null, listURL: list.listURL, thumb: r.entries[0] && vid(r.entries[0].url) ? `https://i.ytimg.com/vi/${vid(r.entries[0].url)}/mqdefault.jpg` : '' };
    if (busyCount() + waiting.length === 0) { batchTotal = 0; batchDone = 0; batchStart = Date.now(); }
    r.entries.forEach((en) => {
      const item = { id: uid(), url: en.url, dest, maxHeight: null, audio, stripAudio: settings.stripAudio,
        videoFormat: settings.videoFormat, audioFormat: settings.audioFormat, playlist: pl };
      batchTotal += 1; waiting.push(item);
      const id = vid(en.url);
      previews[item.id] = { title: en.title || undefined, thumb: id ? `https://i.ytimg.com/vi/${id}/mqdefault.jpg` : '' };
    });
    single = { message: '', failed: false, file: null };
    clipQueued = clipLast; url.value = ''; url.dispatchEvent(new Event('input'));
    pump();
    flash(trf('В очередь добавлено видео: %d', r.entries.length), 6000);
  }

  // ---------- the clipboard ----------
  let clipLast = null, clipQueued = null;
  async function fillFromClipboard() {
    if (!tauri || !tauri.clipboardManager) return;
    let clip = ''; try { clip = ((await tauri.clipboardManager.readText()) || '').trim(); } catch (e) { return; }
    if (clip === clipQueued) return;
    const isNew = clip !== clipLast; clipLast = clip;
    const empty = !url.value.trim();
    if (!(isNew || empty)) return;
    if (!clip || /\s/.test(clip) || !window.__plausible(window.__parse(clip)) || clip === url.value) return;
    url.value = clip; url.dispatchEvent(new Event('input'));
  }
  window.addEventListener('focus', fillFromClipboard);

  function submitCurrent(audio) {
    const link = window.__parse(url.value).href;
    const maxHeight = probe.heights.length ? (settings.quality || null) : null;
    if (isActive(link, audio)) { flashHint(tr('Эта ссылка уже скачивается или стоит в очереди')); return; }
    const wasBusy = busyCount() > 0;
    submit({ id: uid(), url: link, dest: folder, maxHeight, audio, stripAudio: settings.stripAudio,
      videoFormat: settings.videoFormat, audioFormat: settings.audioFormat });
    if (wasBusy) { clipQueued = clipLast; url.value = ''; url.dispatchEvent(new Event('input')); }
  }

  function start() {
    if (!canGo() || !folder) return;
    const audio = modeFromUI() === 'audio';
    const list = detectPlaylist(url.value);
    if (list) startPlaylist(list, audio); else submitCurrent(audio);
  }
  go.addEventListener('click', start);
  url.addEventListener('keydown', (e) => { if (e.key === 'Enter') start(); });

  // ---------- sounds ----------
  let player = null;
  function playSound(file) { try { player = new Audio('sounds/' + file + '.mp3'); player.play().catch(() => {}); } catch (e) {} }
  const voiceFile = () => 'DownloadComplete' + (settings.chimeVoice === 'male' ? 'Male' : '') + (LANG() === 'en' ? 'EN' : '');
  const chime = () => { if (!settings.muteChime) playSound(voiceFile()); };

  // ---------- anonymous reports about breakage (never links or file names) ----------
  const KIND = { crash: 'приложение аварийно закрылось', toolBroken: 'встроенный инструмент не работает', repeated: 'скачивание не удаётся несколько раз подряд' };
  async function diagReport(kind, details) {
    if (!settings.sendDiagnostics) return;
    const sent = load('diagSent', {}), now = Date.now();
    Object.keys(sent).forEach(k => { if (now - sent[k] > 24 * 3600e3) delete sent[k]; });
    if ((sent[kind] && now - sent[kind] < 20 * 3600e3) || Object.keys(sent).length >= 6) return;
    sent[kind] = now; save('diagSent', sent);
    let env = ''; try { env = await tauri.core.invoke('environment_line'); } catch (e) {}
    let id = ''; try { id = localStorage.getItem('installId') || ''; if (!id) { id = uid().slice(0, 6); localStorage.setItem('installId', id); } } catch (e) {}
    tauri.core.invoke('send_telegram', { text: `⚠️ Автоотчёт: ${kind}\n${env} · установка #${id}\n\n${String(details).slice(0, 2800)}` });
  }
  function lastErrorLine(log) {
    const line = String(log || '').split('\n').reverse().find(l => l.includes('ERROR:')) || '';
    return line.replace(/^.*?ERROR:/, '').replace(/https?:\/\/\S+/g, '<ссылка>').replace(/^\s*\[[^\]]+\]\s*[^:\s]+:\s*/, '').trim().slice(0, 220);
  }
  function noteFailure(category, hostName, log) {
    const recent = load('diagFailures', []);
    recent.push({ c: category, h: hostName || '?', e: lastErrorLine(log) });
    if (recent.length >= 3) {
      save('diagFailures', []);
      diagReport(KIND.repeated, 'Три неудачи подряд:\n' + recent.map((x, i) => `${i + 1}. ${x.h} — ${x.c}\n   ${x.e}`).join('\n'));
    } else save('diagFailures', recent);
  }
  const noteSuccess = () => save('diagFailures', []);
  const BREAKAGE = { auth: 'требуется вход / проверка на бота', forbidden: '403 от сайта', format: 'не нашёлся формат', other: 'неизвестная ошибка' };

  // ---------- «Сообщить об ошибке» ----------
  async function reportError() {
    if (!single.failed || single.reportStatus === 'sending' || single.reportStatus === 'sent') return;
    const n = (+localStorage.getItem('errorReportCounter') || 0) + 1;
    try { localStorage.setItem('errorReportCounter', String(n)); } catch (e) {}
    single.reportNumber = n; single.reportStatus = 'sending'; render();
    const report = `Обращение №${n} — Scorpena ${VERSION} (Windows), ошибка при скачивании\n\nСсылка: ${single.url || ''}\nСообщение: ${single.message}\n\nЖурнал:\n${String(single.log || '').slice(-3000) || '(пусто)'}`;
    try { await tauri.clipboardManager.writeText(report); } catch (e) {}   // the fallback if sending fails
    let ok = false; try { ok = await tauri.core.invoke('send_telegram', { text: report }); } catch (e) {}
    single.reportStatus = ok ? 'sent' : 'failed'; render();
  }

  // ---------- applying settings ----------
  function applySpeed() {   // a running download picks the new limit up by carrying on from its partial file
    running.filter(r => !r.paused && r.canPause).forEach(r => { tauri.core.invoke('stop_job', { id: r.item.id }); setTimeout(() => { if (!r.paused) launch(r); }, 400); });
  }

  // ---------- cleanup ----------
  const STALE_DAYS = 7, THRESHOLD = 100e6;
  async function runCleanup(force) {
    const idle = running.length === 0 && waiting.length === 0;
    const partials = idle ? await tauri.core.invoke('stale_partials', { days: STALE_DAYS }) : { paths: [], bytes: 0 };
    const cutoff = Date.now() - STALE_DAYS * 86400000;
    const oldEntries = history.filter(h => h.date < cutoff);
    const histBytes = oldEntries.reduce((n, h) => n + (h.thumb && h.thumb.startsWith('data:') ? h.thumb.length : 0), 0);
    const total = partials.bytes + histBytes;
    const found = total >= (force ? 1 : THRESHOLD) || (force && oldEntries.length > 0);
    if (force) tauri.event.emit('cleanup-result', found);
    if (!found) return;
    const size = total >= 1e9 ? (total / 1e9).toFixed(2).replace('.', LANG() === 'en' ? '.' : ',') + '\u00a0' + tr('ГБ') : Math.max(1, Math.round(total / 1e6)) + '\u00a0' + tr('МБ');
    const choice = await dialog({ title: 'Пора прибраться', message: trf('Старые записи истории и недокачанные видео занимают %@. Удалить их? Твои скачанные файлы останутся на месте.', size),
      buttons: [{ label: 'Позже', value: 'later' }, { label: 'Почистить', value: 'clean', primary: true }] });
    if (choice === 'clean') { history = history.filter(h => h.date >= cutoff); persist(); emitNow(); if (partials.paths.length) tauri.core.invoke('remove_partials', { paths: partials.paths }); }
  }
  function cleanupOnLaunch() {
    const period = { weekly: 7, monthly: 30 }[settings.cleanupReminder];
    if (!period) return;
    if (!settings.lastCleanupCheck) { settings.lastCleanupCheck = Date.now(); persist(); return; }   // the first period is quiet
    if (Date.now() - settings.lastCleanupCheck < period * 86400000) return;
    settings.lastCleanupCheck = Date.now(); persist(); runCleanup(false);
  }

  // ---------- the other windows ----------
  const WINDOWS = {
    lang: ['lang.html', 'Scorpena – video downloader', 440, 300], advanced: ['advanced.html', 'Дополнительно', 460, 780], about: ['about.html', 'О программе', 480, 600], legal: ['legal.html', 'Правовая информация', 520, 640],
    feedback: ['feedback.html', 'Обратная связь', 480, 520], whatsnew: ['whatsnew.html', 'Что нового', 540, 560],
  };
  function openWin(name, query) {
    const w = WINDOWS[name]; if (!w) return;
    tauri.core.invoke('open_window', { label: name, page: w[0] + (query || ''), title: tr(w[1]), width: w[2], height: w[3] });
  }
  document.querySelectorAll('footer a[data-win]').forEach(a => a.addEventListener('click', () => {
    const k = a.dataset.win;
    if (k === 'donate') tauri.core.invoke('open_url', { url: DONATE_URL });
    else if (k === 'share') shareApp();
    else openWin(k);
  }));
  function shareApp() {
    const msg = SHARE_TEXT;
    try { tauri.clipboardManager.writeText(msg); } catch (e) {}
    flash(tr('Текст приглашения скопирован — отправь его другу'), 4000);
  }
  function openAdvanced() { openWin('advanced'); setTimeout(() => emitNow(), 400); }
  document.getElementById('btn-gear').addEventListener('click', openAdvanced);
  document.getElementById('ver').textContent = '(v.' + VERSION + ')';
  document.getElementById('ver').addEventListener('click', () => openWin('whatsnew', '?v=' + VERSION + '#manual'));
  if (tauri) tauri.event.listen('cmd', (e) => {
    if (e.payload.type === 'whatsNewSeen') { settings.lastSeenChangelog = e.payload.version; persist(); }
    const c = e.payload;
    if (c.type === 'langChosen' && window.__afterLang) { const f = window.__afterLang; window.__afterLang = null; f(); }
    if (c.type === 'openAdvanced') openAdvanced();
    if (c.type === 'setSetting') { settings[c.key] = c.value; persist(); if (c.key === 'limitStep') applySpeed(); }
    if (c.type === 'previewVoice') playSound(voiceFile());
    if (c.type === 'cleanNow') runCleanup(true);
  });

  // ---------- closing the program while something downloads ----------
  if (tauri && tauri.window) tauri.window.getCurrentWindow().onCloseRequested(async (ev) => {
    if (!running.length && !waiting.length) return;
    ev.preventDefault();
    const c = await dialog({ title: 'Идёт скачивание', message: 'Если закрыть программу сейчас, скачивание остановится. Оно продолжится, когда ты откроешь программу снова.',
      buttons: [{ label: 'Всё равно закрыть', value: 'quit' }, { label: 'Остаться', value: 'stay', primary: true }] });
    if (c === 'quit') { persist(); await tauri.window.getCurrentWindow().destroy(); }
  });

  // ---------- updating the program (the red «Доступно обновление») ----------
  const updLink = $('upd');
  let latestVersion = null, updating = false;
  const isNewer = (a, b) => { const x = a.split('.').map(Number), y = b.split('.').map(Number); for (let i = 0; i < Math.max(x.length, y.length); i++) { const p = x[i] || 0, q = y[i] || 0; if (p !== q) return p > q; } return false; };
  async function checkForUpdate() {
    try {
      const r = await fetch('https://raw.githubusercontent.com/erickkey/Scorpena/main/version.json?t=' + Math.floor(Date.now() / 1000), { cache: 'no-store' });
      const j = await r.json();
      if (j.version && isNewer(j.version, VERSION)) { latestVersion = j.version; updLink.hidden = false; updLink.textContent = tr('Доступно обновление') + ' (' + j.version + ')'; }
    } catch (e) {}
  }
  function updatePanel({ title, detail, buttons, progress }) {
    document.querySelectorAll('.modal-bg.upd-panel').forEach(n => n.remove());
    const wrap = document.createElement('div'); wrap.className = 'modal-bg upd-panel';
    wrap.innerHTML = `<div class="modal wide"><img src="logo.png" alt="" style="width:56px;height:56px;margin:0 auto"><div class="mt">${esc(title)}</div>
      ${detail ? `<div class="mm" style="white-space:pre-line">${esc(detail)}</div>` : ''}
      ${progress === undefined ? '' : `<div class="bar dlg ${progress === null ? 'busy' : ''}"><i style="width:${(progress || 0) * 100}%"></i></div>`}<div class="mb"></div></div>`;
    (buttons || []).forEach(b => { const el = document.createElement('button'); el.className = b.primary ? 'pill' : 'soft'; el.style.minWidth = '96px'; el.textContent = b.label; el.onclick = b.f; wrap.querySelector('.mb').appendChild(el); });
    document.body.appendChild(wrap); return wrap;
  }
  const closeUpd = () => document.querySelectorAll('.modal-bg.upd-panel').forEach(n => n.remove());
  function startUpdate() {
    if (updating || !latestVersion) return;
    if (running.length) { updatePanel({ title: tr('Сейчас идёт скачивание'), detail: tr('Дождись окончания скачивания и нажми кнопку обновления ещё раз.'), buttons: [{ label: tr('Понятно'), primary: true, f: closeUpd }] }); return; }
    updatePanel({ title: trf('Вышла новая версия %@', latestVersion), detail: tr('Обновимся прямо сейчас? Займёт около минуты, программа сама перезапустится. Настройки и история сохранятся.'),
      buttons: [{ label: tr('Позже'), f: closeUpd }, { label: tr('Обновить'), primary: true, f: () => beginInstall(latestVersion) }] });
  }
  async function beginInstall(version) {
    updating = true; updLink.classList.add('busy');
    const failed = (reason) => { updating = false; updLink.classList.remove('busy');
      updatePanel({ title: tr('Обновиться не получилось'), detail: reason + '\n' + tr('Ничего не сломалось: осталась прежняя версия.'),
        buttons: [{ label: tr('Закрыть'), f: closeUpd }, { label: tr('Скачать вручную'), primary: true, f: () => { tauri.core.invoke('open_url', { url: WIN_URL }); closeUpd(); } }] }); };
    const panel = updatePanel({ title: tr('Загружаю новую версию…'), detail: '0%', progress: 0 });
    const un = await tauri.event.listen('update-progress', (e) => { const f = e.payload; const d = panel.querySelector('.mm'); if (d) d.textContent = Math.round(f * 100) + '%'; const i = panel.querySelector('.bar i'); if (i) i.style.width = f * 100 + '%'; });
    let path;
    try { path = await tauri.core.invoke('download_update'); } catch (err) { un(); return failed(String(err)); }
    un();
    updatePanel({ title: tr('Проверяю загрузку…'), detail: tr('Убеждаюсь, что всё скачалось без повреждений.'), progress: null });
    await new Promise(r => setTimeout(r, 800));
    updatePanel({ title: tr('Ставлю обновление…'), detail: tr('Сейчас программа перезапустится.'), progress: null });
    try { localStorage.setItem('pendingAppUpdateVersion', version); } catch (e) {}
    persist();
    const ok = await tauri.core.invoke('install_update', { installer: path });
    if (!ok) failed('');
  }
  updLink.addEventListener('click', startUpdate);
  function showUpdateResult() {   // after the program has restarted into the new version
    let target = null; try { target = localStorage.getItem('pendingAppUpdateVersion'); localStorage.removeItem('pendingAppUpdateVersion'); } catch (e) {}
    if (!target) return;
    if (target === VERSION) updatePanel({ title: trf('Готово! Теперь у тебя версия %@ ✅', VERSION), buttons: [{ label: tr('Отлично'), primary: true, f: closeUpd }] });
    else { updatePanel({ title: tr('Обновиться не получилось'), detail: tr('Новая версия не запустилась, поэтому вернули прежнюю. Ничего не сломалось — можно скачать новую вручную.'),
      buttons: [{ label: tr('Закрыть'), f: closeUpd }, { label: tr('Скачать вручную'), primary: true, f: () => { tauri.core.invoke('open_url', { url: WIN_URL }); closeUpd(); } }] });
      diagReport('новая версия не запустилась, вернули прежнюю', `Ставили версию ${target}, запущена ${VERSION}.`); }
  }

  // ---------- missing tools, the first-launch login check, the daily tool update ----------
  function showMissingTools() {
    $('banner').innerHTML = `<div class="banner"><b>${esc(tr('Внутри программы не хватает файлов'))}</b><span>${esc(tr('Скачай Scorpena заново: все файлы встанут на место, настройки и история сохранятся.'))}</span>
      <div><button class="soft sm" id="getApp">${esc(tr('Открыть страницу загрузки'))}</button></div></div>`;
    $('getApp').onclick = () => tauri.core.invoke('open_url', { url: WIN_URL });
  }
  async function afterLaunchChecks() {
    checkForUpdate(); showUpdateResult();
    tauri.core.invoke('take_crash_report').then(t => { if (t) diagReport(KIND.crash, t); });
    tauri.core.invoke('check_bundled_tools').then(p => { if (p.length) { diagReport(KIND.toolBroken, p.join('\n')); if (p.some(x => x.includes('файла нет'))) showMissingTools(); } });
    if (!settings.cookiePreflightDone) setTimeout(async () => { try { settings.cookieOrder = await tauri.core.invoke('cookie_preflight'); settings.cookiePreflightDone = true; persist(); } catch (e) {} }, 4000);
    setTimeout(async () => {   // the daily update of yt-dlp: only when nothing is going on
      if (running.length || probe.busy || Date.now() - (settings.lastToolCheck || 0) < 20 * 3600e3) return;
      settings.lastToolCheck = Date.now(); persist();
      try { await tauri.core.invoke('update_tools'); } catch (e) {}
    }, 8000);
  }

  // ---------- the window follows the height of its content ----------
  function fitWindow() {
    if (!tauri || !tauri.window || !tauri.dpi) return;
    const main = document.querySelector('main'); if (!main) return;
    const h = Math.min(900, Math.max(400, Math.ceil(main.getBoundingClientRect().height) + 64));
    if (Math.abs(h - innerHeight) < 4) return;
    try { tauri.window.getCurrentWindow().setSize(new tauri.dpi.LogicalSize(innerWidth, h)); } catch (e) {}
  }
  if (window.ResizeObserver) new ResizeObserver(() => fitWindow()).observe(document.querySelector('main'));

  window.addEventListener('langchange', () => {
    if (folder) { folderBtn.textContent = tr('Папка:') + ' ' + folderName(); }
    renderQuality(); lastKey = ''; render();
    const v = $('ver'); if (v) v.title = tr('Список изменений');
  });

  // ---------- start-up ----------
  window.scorpena = { get running() { return running; }, get waiting() { return waiting; }, get finished() { return finished; },
    pause, resume, cancel, pauseAll, resumeAll, batch: () => ({ batchTotal, batchDone, batchStart }), busyCount, settings, persist, get probe() { return probe; } };
  (async () => {
    if (!tauri) return;
    await initFolder();
    renderQuality();
    const proceed = () => {
      fillFromClipboard();
      if (!settings.muteLaunchSound) playSound('AppLaunch');
      cleanupOnLaunch();
      // «Что нового»: shown once per version, until the user presses the button
      if (CHANGELOG[VERSION] && settings.lastSeenChangelog !== VERSION) setTimeout(() => openWin('whatsnew', '?v=' + VERSION), 600);
      afterLaunchChecks();
    };
    // first launch: the language comes first
    if (languageChosen()) proceed(); else { openWin('lang'); window.__afterLang = proceed; }
    // the queue left from the last time: everything comes back, paused ones stay paused
    const saved = load('queue', []);
    if (saved.length) {
      batchStart = Date.now();
      saved.forEach(i => { const { paused, ...item } = i; if (paused) item.startPaused = true; waiting.push(item); batchTotal += 1; loadPreview(item); });
      pump();
    }
    render();
  })();
})();
