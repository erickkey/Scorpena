// The information windows: «О программе», «Правовая информация», «Обратная связь», «Что нового».
(() => {
  const tauri = window.__TAURI__, page = document.body.dataset.page;
  const content = document.getElementById('content'), foot = document.getElementById('foot');
  const gearSvg = '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></svg>';
  // A "⚙" inside a text is the real gear button: it opens «Дополнительно».
  const T = (s) => esc(tr(s));
  const withGear = (t) => esc(tr(t)).replace(/⚙/g, `<button class="gear" data-open="advanced" title="${T('Дополнительно')}">${gearSvg}</button>`);
  const list = (title, items) => `<div class="card"><h3>${T(title)}</h3><ul>${items.map(i => `<li><span>${withGear(i)}</span></li>`).join('')}</ul></div>`;
  const titleRow = (t, sub) => `<div class="title-row"><img src="logo.png" alt=""><div><div class="t">${T(t)}</div>${sub ? `<div class="sec">${T(sub)}</div>` : ''}</div></div>`;
  const btn = (label, id) => `<button class="pill" id="${id}">${T(label)}</button>`;

  if (page === 'about') {
    const A = ABOUT;
    content.innerHTML = `<div class="stack"><div class="accent">${withGear(A.warn)}</div>
      <div class="about-head"><img src="logo.png" alt=""><div><div class="n">SCORPENA</div><div class="s">video downloader</div></div></div>
      <div class="sec" style="font-size:11px">by Yaroslav Lukyanov</div><div class="tagline">${T(A.tagline)}</div><div class="sec">${T(A.intro)}</div>
      ${list('Что есть', A.have)}${list('Чего нет', A.havent)}
      <div><div class="sec" style="margin-bottom:10px">${T(A.free)}</div><button class="soft" id="donate">Поддержать</button></div></div>`;
    foot.innerHTML = btn('Благодарю', 'close');
    document.getElementById('donate').onclick = () => tauri.core.invoke('open_url', { url: DONATE_URL });
  } else if (page === 'legal') {
    const L = LEGAL;
    content.innerHTML = `<div class="stack">${titleRow('Правовая информация')}<div class="grey">${T(L.note)}</div>
      <div class="card stack" style="gap:10px"><div style="font-size:13px"><b>${T(L.legalLead)}</b> ${T(L.legalRest)}</div><div style="font-size:13px">${T(L.usage)}</div>
      <div style="font-size:13px"><b>${T(L.noLead)}</b> ${T(L.noRest)}</div></div>
      ${list('Ответственность', L.resp)}<div class="card" style="font-size:13px"><b>${T(L.crashLead)}</b> ${T(L.crashRest)}</div>
      <div class="sec" style="padding:0 4px">${T(L.final)}</div></div>`;
    foot.innerHTML = btn('Понятно', 'close');
  } else if (page === 'whatsnew') {
    const v = new URLSearchParams(location.search).get('v') || VERSION;
    const head = HEADLINES[v];
    const items = (CHANGELOG[v] || []).map(T);
    const cut = DIVIDER_AFTER[v];
    const lis = items.map((t, i) => `<li><span>${t}</span></li>${cut === i + 1 ? '<hr>' : ''}`).join('');
    content.innerHTML = `<div class="stack">${head
      ? `<div class="hero"><img src="logo.png" alt=""><div class="i">${T(head[0])}</div><div class="nm"><b>Scorpena</b><span> – video downloader</span></div><div class="sec">${T(head[2])}</div></div>`
      : titleRow(trf('Список изменений (v.%@)', v))}<div class="card"><ul>${lis}</ul></div></div>`;
    foot.innerHTML = btn(location.hash === '#manual' ? 'Закрыть' : 'Круто', 'close');
    document.getElementById('close').addEventListener('click', () => { if (location.hash !== '#manual') tauri.event.emit('cmd', { type: 'whatsNewSeen', version: v }); });
  } else if (page === 'feedback') {
    let name = '', contact = '';
    try { name = localStorage.getItem('feedbackName') || ''; contact = localStorage.getItem('feedbackContact') || ''; } catch (e) {}
    content.innerHTML = `<div class="stack">${titleRow('Обратная связь', 'Вопросы, предложения, ошибки — что угодно. Уходит прямо разработчику.')}
      <div class="field"><label>${T('Обращение')}</label><textarea id="msg" rows="4" placeholder="${T('Напиши сюда…')}"></textarea></div>
      <div class="field"><label>${T('Имя (необязательно)')}</label><input id="name" placeholder="${T('Как тебя зовут')}" value="${esc(name)}"></div>
      <div class="field"><label>${T('Как связаться (необязательно)')}</label><input id="contact" placeholder="${T('Например, ссылка на Telegram')}" value="${esc(contact)}"></div>
      <div class="note" id="note"></div></div>`;
    foot.innerHTML = btn('Отправить', 'close');
    const send = document.getElementById('close'), msg = document.getElementById('msg'), note = document.getElementById('note');
    const sync = () => { send.disabled = !msg.value.trim(); }; msg.addEventListener('input', sync); sync();
    send.addEventListener('click', async () => {
      const text = msg.value.trim(); if (!text) return;
      let last = 0; try { last = +localStorage.getItem('lastFeedbackSendTime') || 0; } catch (e) {}
      const waited = (Date.now() - last) / 1000;
      if (waited < 60) { note.className = 'note'; note.textContent = trf('Подожди ещё %d с перед следующим сообщением.', Math.ceil(60 - waited)); return; }
      const n = document.getElementById('name').value.trim(), c = document.getElementById('contact').value.trim();
      try { localStorage.setItem('feedbackName', n); localStorage.setItem('feedbackContact', c); localStorage.setItem('lastFeedbackSendTime', String(Date.now())); } catch (e) {}
      const info = [n && `Имя: ${n}`, c && `Связь: ${c}`].filter(Boolean);
      const header = info.length ? `Обратная связь (${info.join(', ')}):` : 'Обратная связь:';
      msg.value = ''; sync(); note.className = 'note ok'; note.textContent = 'Обращение отправлено';
      tauri.core.invoke('send_telegram', { text: `${header}\n\n${text}` });
      setTimeout(closeMe, 1500);
    });
    send.removeAttribute('id'); send.id = 'send';
  }
  window.addEventListener('langchange', () => location.reload());
  const close = document.getElementById('close'); if (close) close.addEventListener('click', closeMe);
  document.addEventListener('click', (e) => { const g = e.target.closest('[data-open]'); if (g) cmd('openAdvanced'); });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && page !== 'feedback') closeMe(); });
})();
