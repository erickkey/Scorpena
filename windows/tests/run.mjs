// Drives the installed, shipped Scorpena on a Windows machine through the WebView2 debugging port.
import puppeteer from 'puppeteer-core';
import { spawn, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const OUT = path.resolve('out'); fs.mkdirSync(OUT, { recursive: true });
const log = [];
const say = (s) => { console.log(s); log.push(s); fs.writeFileSync(path.join(OUT, 'log.txt'), log.join('\n')); };
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const ps = (...a) => { try { return execFileSync('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.resolve('win.ps1'), ...a], { encoding: 'utf8' }).trim(); } catch (e) { return 'ERR ' + e.message; } };
const desk = (name) => ps('shot', path.join(OUT, name + '.png'));
const results = {};
const withTimeout = (p, ms, name) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error('step timed out after ' + ms / 1000 + ' s')), ms))]);
setTimeout(() => { say('global time limit reached'); desk('global-timeout'); process.exit(0); }, 18 * 60 * 1000);
async function step(name, fn, ms = 200000) {
  try { const r = await withTimeout(fn(), ms, name); results[name] = r === undefined ? 'ok' : r; say(`✔ ${name}: ${JSON.stringify(results[name])}`); }
  catch (e) { results[name] = 'FAIL ' + e.message; say(`✘ ${name}: ${e.message}`); desk('fail-' + name); }
  fs.writeFileSync(path.join(OUT, 'results.json'), JSON.stringify(results, null, 1));
}

// ---- find and start the installed program
const dirs = [path.join(process.env.LOCALAPPDATA, 'Scorpena'), path.join(process.env.LOCALAPPDATA, 'Programs', 'Scorpena')];
let exe = null;
for (const d of dirs) if (fs.existsSync(d)) for (const f of fs.readdirSync(d)) if (/\.exe$/i.test(f) && !/unins|uninstall/i.test(f)) exe = path.join(d, f);
if (!exe) { say('installed exe not found'); process.exit(1); }
say('exe: ' + exe);
const procName = path.basename(exe, '.exe');
const dataDir = path.join(process.env.APPDATA, 'Scorpena');
const downloads = path.join(process.env.USERPROFILE, 'Downloads');
fs.mkdirSync(downloads, { recursive: true });

// WebView2 reads extra browser arguments from this policy key (the program passes its own, so the env variable is ignored)
try { execFileSync('powershell', ['-NoProfile', '-Command', "New-Item -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge\\WebView2\\AdditionalBrowserArguments' -Force | Out-Null; Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge\\WebView2\\AdditionalBrowserArguments' -Name '*' -Value '--remote-debugging-port=9222'"]); say('policy key set'); } catch (e) { say('policy key failed: ' + e.message); }
const child = spawn(exe, [], { env: { ...process.env, WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: '--remote-debugging-port=9222' }, detached: false, stdio: 'ignore' });
await sleep(8000);
let browser;
for (let i = 0; i < 20 && !browser; i++) { try { browser = await puppeteer.connect({ browserURL: 'http://127.0.0.1:9222', defaultViewport: null, protocolTimeout: 20000 }); } catch (e) { await sleep(1500); } }
if (!browser) {
  say('cannot connect to the program'); desk('no-connect');
  const sh = (c) => { try { return execFileSync('powershell', ['-NoProfile', '-Command', c], { encoding: 'utf8' }); } catch (e) { return 'ERR ' + e.message; } };
  say('listening: ' + sh('netstat -ano | findstr LISTENING | findstr 127.0.0.1'));
  say('webview2: ' + sh("Get-CimInstance Win32_Process -Filter \"name='msedgewebview2.exe'\" | Select-Object -First 3 -ExpandProperty CommandLine"));
  say('json/version: ' + sh('try { (Invoke-WebRequest http://127.0.0.1:9222/json/version -UseBasicParsing).Content } catch { $_.Exception.Message }'));
  process.exit(1);
}
const pages = async () => (await browser.pages());
const pageBy = async (re, wait = 10000) => { const t0 = Date.now(); while (Date.now() - t0 < wait) { for (const p of await pages()) if (re.test(p.url())) return p; await sleep(400); } return null; };

let main = await pageBy(/tauri\.localhost\/(index\.html)?$|tauri\.localhost\/?$/);
if (!main) { for (const p of await pages()) say('page: ' + p.url()); main = (await pages())[0]; }

desk('01-just-started');
for (const p of await pages()) { let info = ''; try { info = await withTimeout(p.evaluate(() => document.readyState + ' | ' + document.title + ' | text:' + (document.body ? document.body.innerText.length : -1)), 8000); } catch (e) { info = 'eval failed: ' + e.message; } say('page: ' + p.url() + ' -> ' + info); }
say('windows: ' + ps('windows', procName));
await step('settings-first-launch', async () => {
  await main.evaluate(() => { localStorage.setItem('lang', 'ru'); localStorage.setItem('welcomed', '1'); localStorage.setItem('settings', JSON.stringify({ lastSeenChangelog: '3.1.1', cookiePreflightDone: true, lastToolCheck: Date.now() })); });
  await main.evaluate(() => location.reload()); await sleep(5000);
  await main.screenshot({ path: path.join(OUT, 'main.png') }); desk('desktop-main');
  return { title: await main.title(), windows: JSON.parse(ps('windows', procName) || '[]') };
});

const status = () => main.evaluate(() => (document.querySelector('#progress .txt') || {}).textContent || '');
const typeUrl = async (u) => { await main.evaluate((u) => { const e = document.getElementById('url'); e.value = u; e.dispatchEvent(new Event('input')); }, u); await sleep(500); };
const waitStatus = async (re, ms) => { const t0 = Date.now(); let s = ''; while (Date.now() - t0 < ms) { s = await status(); if (re.test(s)) return s; await sleep(700); } throw new Error('status stayed: ' + s); };

await step('download-direct-mp4', async () => {
  await typeUrl('https://www.w3schools.com/html/mov_bbb.mp4');
  await main.click('#go');
  const s = await waitStatus(/Готово|Ошибка/, 120000);
  const files = fs.readdirSync(downloads).filter(f => f.includes('Scorpena video downloader'));
  desk('after-download');
  return { status: s, files };
});

await step('pause-resume-kills-process-tree', async () => {
  await main.evaluate(() => window.__TAURI__.event.emit('cmd', { type: 'setSetting', key: 'limitStep', value: 0 }));
  await sleep(500);
  await typeUrl('https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/1080/Big_Buck_Bunny_1080_10s_30MB.mp4');
  await main.click('#go');
  await waitStatus(/\d+%/, 90000);
  await sleep(2000);
  const before = ps('procs');
  await main.click('button[data-act=pause]');
  await sleep(2500);
  const alive = execFileSync('powershell', ['-NoProfile', '-Command', '(Get-Process yt-dlp -ErrorAction SilentlyContinue | Measure-Object).Count'], { encoding: 'utf8' }).trim();
  const pausedStatus = await status();
  await main.click('button[data-act=resume]');
  await sleep(4000);
  const resumed = await status();
  await main.click('button[data-act=cancel]');
  await sleep(1500);
  return { ytdlpAfterPause: alive, pausedStatus, resumed };
});

await step('login-required-vimeo', async () => {
  await typeUrl('https://vimeo.com/76979871');
  await main.click('#go');
  await waitStatus(/Ошибка/, 120000);
  await sleep(500);
  const text = await main.evaluate(() => document.getElementById('progress').innerText);
  desk('auth-error');
  await main.screenshot({ path: path.join(OUT, 'auth-error-page.png') });
  return { hasFirefox: text.includes('Открыть в Firefox'), hasLogin: text.includes('Войти в окне'), hasRetry: text.includes('Повторить'), head: text.slice(0, 120) };
});

await step('login-window-saves-encrypted-cookies', async () => {
  await main.evaluate(() => document.querySelector('[data-act=login]').click());
  let login = await pageBy(/vimeo\.com/, 20000);
  if (!login) { for (const p of await pages()) say('page: ' + p.url()); throw new Error('login window did not open'); }
  await sleep(4000);
  desk('login-window');
  await login.setCookie({ name: 'scorpena_test', value: 'hello', domain: '.vimeo.com', path: '/', secure: true });
  say('closing: ' + ps('close', procName, 'Вход'));
  await sleep(6000);
  const file = path.join(dataDir, 'login-cookies.dat');
  const exists = fs.existsSync(file);
  let raw = '', plain = '';
  if (exists) { raw = fs.readFileSync(file).slice(0, 12).toString('latin1'); plain = ps('decrypt', file); }
  return { exists, startsPlain: raw.startsWith('# Netscape'), decryptedHasCookie: plain.includes('scorpena_test'), decryptedHead: plain.slice(0, 40) };
});

await step('window-sizes', async () => {
  const sizes = {};
  const open = async (sel) => { await main.evaluate((s) => document.querySelector(s).click(), sel); await sleep(1800); };
  for (const [name, sel] of [['downloads', '#btn-downloads'], ['advanced', '#btn-gear'], ['about', '[data-win=about]'], ['legal', '[data-win=legal]'], ['feedback', '[data-win=feedback]'], ['whatsnew', '#ver']]) {
    await open(sel); desk('win-' + name);
  }
  return JSON.parse(ps('windows', procName) || '[]');
});

await step('leftovers', async () => ({
  temp: fs.readdirSync(process.env.TEMP).filter(f => f.startsWith('scorpena-login')),
  data: fs.readdirSync(dataDir),
  downloads: fs.readdirSync(downloads),
}));

try { await browser.disconnect(); } catch (e) {}
child.kill();
try { execFileSync('taskkill', ['/F', '/IM', 'yt-dlp.exe'], { stdio: 'ignore' }); } catch (e) {}
process.exit(0);
