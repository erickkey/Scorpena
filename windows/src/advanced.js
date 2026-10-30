// The «Дополнительно» window. The main window owns the settings; this one reads them and sends changes.
(() => {
  const tauri = window.__TAURI__;
  const content = document.getElementById('content');
  const STEPS = [5, 10, 20, 30, 50, 75, 100, 150, 200, 0];
  const load = () => { try { return Object.assign({ muteChime: false, chimeVoice: 'female', muteLaunchSound: false, limitStep: 9, cleanupReminder: 'weekly', sendDiagnostics: true }, JSON.parse(localStorage.getItem('settings') || '{}')); } catch (e) { return {}; } };
  let S = load(), busy = false, tools = { version: null, checking: false, status: '' }, cleanupNote = '';
  const set = (key, value) => { S[key] = value; cmd('setSetting', { key, value }); render(); };

  const speedTitle = (i) => STEPS[i] === 0 ? tr('Без ограничения') : trf('%d Мбит/с', STEPS[i]);
  const speedNote = (i) => { const v = STEPS[i]; if (!v) return ''; return trf('≈ %@ МБ/с', String(v / 8).replace('.', LANG() === 'en' ? '.' : ',')); };
  const seg = (name, options, selected) => `<div class="segs" data-seg="${name}">${options.map(([id, t]) => `<button class="seg ${id === selected ? 'on' : ''}" data-v="${id}">${t}</button>`).join('')}</div>`;
  const check = (key, label, on) => `<label class="checkrow"><input type="checkbox" data-check="${key}" ${on ? 'checked' : ''}>${label}</label>`;

  const WINDOWS = /Windows/i.test(navigator.userAgent) || localStorage.getItem('forceWin') === '1';
  let loginNote = '';
  function render() {
    const keep = content.scrollTop;
    content.innerHTML = `<div class="adv">
      <div class="card blk"><h3>Уведомления</h3>
        ${check('chime', 'Звук уведомления о скачивании', !S.muteChime)}
        <div class="row-inline indent ${S.muteChime ? 'dim' : ''}"><span style="font-size:13px">Голос</span>${seg('voice', [['female', 'Женский'], ['male', 'Мужской']], S.chimeVoice)}</div>
        ${check('launch', 'Звук запуска приложения', !S.muteLaunchSound)}</div>
      <div class="card blk"><h3>Скорость скачивания</h3>
        <div class="slider"><input type="range" id="speed" min="0" max="${STEPS.length - 1}" step="1" value="${S.limitStep}">
          <div class="val">${speedTitle(S.limitStep)}${speedNote(S.limitStep) ? `<small>${speedNote(S.limitStep)}</small>` : ''}</div></div></div>
      <div class="card blk"><h3>Напоминание об очистке</h3>
        ${seg('cleanup', [['weekly', 'Раз в неделю'], ['monthly', 'Раз в месяц'], ['never', 'Никогда']], S.cleanupReminder)}
        <div class="row-inline"><button class="minibtn" id="cleanNow">Очистить сейчас</button>${cleanupNote ? `<span class="small">${esc(cleanupNote)}</span>` : ''}</div></div>
      <div class="card blk"><h3>Обновление встроенных инструментов</h3>
        <div class="small">Программа скачивает видео с помощью внутренних инструментов и сама их обновляет. Если видео перестало скачиваться — нажми «Проверить сейчас».</div>
        <div class="row-inline"><button class="minibtn" id="checkTools" ${busy || tools.checking ? 'disabled' : ''}>${tools.checking ? tr('Проверяю…') : tr('Проверить сейчас')}</button>
          ${tools.version ? `<span class="small">yt-dlp ${esc(tools.version)}</span>` : ''}</div>
        ${tools.status ? `<div class="small" style="white-space:pre-line">${esc(tools.status)}</div>` : ''}</div>
      ${WINDOWS ? `<div class="card blk"><h3>Входы в аккаунты</h3>
        <div class="small">Когда ты входишь на сайт через «Войти в окне», вход хранится на этом компьютере в зашифрованном виде и доступен только тебе.</div>
        <div class="row-inline"><button class="minibtn" id="forgetLogins">${tr('Забыть входы в аккаунты')}</button>${loginNote ? `<span class="small">${esc(loginNote)}</span>` : ''}</div></div>` : ''}
      <div class="card blk"><h3>Язык</h3>${seg('lang', [['ru', FLAGS.ru + ' Русский'], ['en', FLAGS.en + ' English']], LANG())}</div>
      <div class="card blk"><h3>Отчёты о сбоях</h3>
        ${check('diag', 'Отправлять разработчику анонимные отчёты о сбоях', S.sendDiagnostics)}
        <div class="small">Анонимно, без ссылок и личных данных.</div></div>
    </div>`;
    content.scrollTop = keep;
  }

  content.addEventListener('change', (e) => {
    const c = e.target.dataset.check;
    if (c === 'chime') set('muteChime', !e.target.checked);
    else if (c === 'launch') set('muteLaunchSound', !e.target.checked);
    else if (c === 'diag') set('sendDiagnostics', e.target.checked);
  });
  content.addEventListener('input', (e) => { if (e.target.id === 'speed') { S.limitStep = +e.target.value; cmd('setSetting', { key: 'limitStep', value: S.limitStep }); const v = content.querySelector('.slider .val'); v.innerHTML = speedTitle(S.limitStep) + (speedNote(S.limitStep) ? `<small>${speedNote(S.limitStep)}</small>` : ''); } });
  content.addEventListener('click', async (e) => {
    const b = e.target.closest('.seg');
    if (b) {
      const kind = b.parentElement.dataset.seg;
      if (kind === 'voice') { set('chimeVoice', b.dataset.v); cmd('previewVoice'); }
      else if (kind === 'cleanup') set('cleanupReminder', b.dataset.v);
      else if (kind === 'lang') setLanguage(b.dataset.v);
      return;
    }
    if (e.target.id === 'forgetLogins') { await tauri.core.invoke('forget_logins'); loginNote = tr('Входы удалены'); render(); }
    if (e.target.id === 'cleanNow') { cleanupNote = ''; cmd('cleanNow'); }
    if (e.target.id === 'checkTools' && !busy) {
      tools.checking = true; tools.status = ''; const start = Date.now(); let stage = 1; render();
      const WHAT = { 1: tr('Проверяю на GitHub, вышла ли новая версия…'), 2: tr('Скачиваю новую версию (около 54 МБ) и сверяю контрольную сумму…'), 3: tr('Проверяю, что новая версия работает с YouTube, и только потом заменяю…') };
      const text = () => trf('Шаг %d из 3 · %@', stage, WHAT[stage]) + ' · ' + trf('%d с', Math.floor((Date.now() - start) / 1000)) + (stage >= 2 ? '\n' + tr('Обычно занимает до минуты.') : '');
      tools.status = text(); render();
      const timer = setInterval(() => { tools.status = text(); render(); }, 1000);
      const un = await tauri.event.listen('tool-stage', (ev) => { stage = ev.payload; });
      const r = await tauri.core.invoke('update_tools');
      clearInterval(timer); un();
      const secs = Math.round((Date.now() - start) / 1000);
      tools.checking = false; tools.version = r.kind === 'updated' ? r.to : (r.kind === 'upToDate' ? r.from : tools.version);
      tools.status = { upToDate: trf('У тебя последняя версия (%@). Проверка заняла %d с.', r.from, secs),
        updated: trf('Обновлено: %@ → %@ ✅ (за %d с)', r.from, r.to, secs), keptOld: trf('Новая версия %@ не прошла проверку — оставил %@.', r.to, r.from),
        offline: tr('Не удалось проверить обновления — нет связи с интернетом.'), failed: tr('Не удалось проверить обновления.') }[r.kind];
      render();
    }
  });
  document.getElementById('close').addEventListener('click', closeMe);
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeMe(); });
  window.addEventListener('storage', (e) => { if (e.key === 'settings') { if (document.activeElement && document.activeElement.id === 'speed') return; S = load(); render(); } });
  tauri.event.listen('snapshot', (e) => { const b = e.payload.running.length > 0; if (b !== busy) { busy = b; render(); } });
  tauri.event.listen('cleanup-result', (e) => { cleanupNote = e.payload ? '' : 'Чистить пока нечего.'; render(); });
  tauri.core.invoke('tools_version').then(v => { tools.version = v; render(); });
  window.addEventListener('langchange', () => render());
  render();
  cmd('sync');
})();
