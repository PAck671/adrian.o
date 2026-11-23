'use strict';
const $ = (query) => document.querySelector(query);

const state = {
  target: store.get('tvTarget') === 'lg' ? 'lg' : 'google',
  tab: 'remote',
  google: { host: store.get('tvHost') || '192.168.12.183', link: 'idle', message: '', apps: [] },
  lg: { host: store.get('lgHost') || '192.168.12.196', link: 'idle', message: '', apps: [], inputs: [], paused: false },
};
let googleConnecting = null;
let lgConnecting = null;

function setLink(tv, link, message = '') {
  tv.link = link;
  tv.message = message;
  renderBanner();
}

let toastTimer;
function notice(text) {
  const toast = $('#toast');
  toast.textContent = text;
  toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { toast.hidden = true; }, 4000);
}

function connectGoogle() {
  googleConnecting ??= performGoogle().finally(() => { googleConnecting = null; });
  return googleConnecting;
}

async function performGoogle() {
  const tv = state.google;
  if (!P.isPrivateIPv4(tv.host)) return setLink(tv, 'failed', "Enter your TV's Wi-Fi address in the TV tab.");
  if (adb.up) return setLink(tv, 'connected');
  setLink(tv, 'connecting');
  try {
    await adb.connect(tv.host, () => setLink(tv, 'approve'));
    setLink(tv, 'connected');
  } catch {
    return setLink(tv, 'failed', "Can't reach the TV. Check that the Echo is on the same Wi-Fi.");
  }
  if (!tv.apps.length) refreshGoogle();
}

async function run(line) {
  for (let attempt = 0; attempt < 2; attempt++) {
    if (!adb.up) await connectGoogle();
    if (!adb.up) return null;
    try {
      return await adb.shell(line);
    } catch (error) {
      if (error.message === 'timeout') { notice("The TV didn't answer in time."); return null; }
      adb.drop();
      if (attempt === 1) setLink(state.google, 'failed', 'Lost the TV connection.');
    }
  }
  return null;
}

async function refreshGoogle() {
  const output = await run(command.listApps);
  if (output !== null) { state.google.apps = P.parseApps(output); renderApps(); }
}

function connectLG() {
  lgConnecting ??= performLG().finally(() => { lgConnecting = null; });
  return lgConnecting;
}

async function performLG() {
  const tv = state.lg;
  if (!P.isPrivateIPv4(tv.host)) return setLink(tv, 'failed', "Enter your LG TV's Wi-Fi address in the TV tab.");
  if (lg.up) return setLink(tv, 'connected');
  setLink(tv, 'connecting');
  try {
    await lg.connect(tv.host, () => setLink(tv, 'approve'));
    setLink(tv, 'connected');
  } catch (error) {
    if (error.message === 'certificate') return setLink(tv, 'failed', "The LG TV's security certificate changed. If you trust it, use Forget LG pairing in the TV tab.");
    if (error.message === 'rejected') return setLink(tv, 'failed', "The LG TV didn't allow this Echo. Tap Retry, then choose Accept on the TV.");
    return setLink(tv, 'failed', "Can't reach the LG TV. If it's off, press Power.");
  }
  if (!tv.apps.length) refreshLG();
}

async function requestLG(uri, payload) {
  for (let attempt = 0; attempt < 2; attempt++) {
    if (!lg.up) await connectLG();
    if (!lg.up) return null;
    try {
      return await lg.request(uri, payload);
    } catch (error) {
      if (error.refused) { notice(error.message); return null; }
      if (error.message === 'timeout') { notice("The TV didn't answer in time."); return null; }
      lg.drop();
      if (attempt === 1) setLink(state.lg, 'failed', 'Lost the LG TV connection.');
    }
  }
  return null;
}

async function buttonLG(name) {
  for (let attempt = 0; attempt < 2; attempt++) {
    if (!lg.up) await connectLG();
    if (!lg.up) return;
    try {
      await lg.button(name);
      return;
    } catch (error) {
      if (error.refused) { notice(error.message); return; }
      lg.drop();
      if (attempt === 1) setLink(state.lg, 'failed', 'Lost the LG TV connection.');
    }
  }
}

async function refreshLG() {
  const apps = await requestLG(LG.apps);
  if (apps) {
    const seen = new Set();
    state.lg.apps = (apps.launchPoints || [])
      .filter((p) => typeof p.id === 'string' && typeof p.title === 'string' && !seen.has(p.id) && seen.add(p.id))
      .map((p) => ({ id: p.id, name: p.title }))
      .sort((x, y) => x.name.localeCompare(y.name));
  }
  const inputs = await requestLG(LG.inputs);
  if (inputs) {
    state.lg.inputs = (inputs.devices || [])
      .filter((d) => typeof d.id === 'string')
      .map((d) => ({ id: d.id, name: typeof d.label === 'string' ? d.label : d.id, connected: !!d.connected }));
  }
  renderApps();
}

// The LG can't be woken over Wi-Fi, but the Google TV box can turn it on through HDMI-CEC.
async function wakeLG() {
  setLink(state.lg, 'connecting');
  if ((await run(command.key(KEY.wakeup))) === null) {
    return setLink(state.lg, 'failed', "Couldn't wake the LG TV through the Google TV box.");
  }
  await sleep(8000);
  connectLG();
}

async function pressLG(code) {
  if (code === KEY.power) {
    if (!lg.up) return wakeLG();
    await requestLG(LG.turnOff);
    lg.drop();
    setLink(state.lg, 'failed', 'LG TV is off. Press Power to turn it on.');
  } else if (code === KEY.playPause) {
    state.lg.paused = !state.lg.paused;
    await requestLG(state.lg.paused ? LG.pause : LG.play);
  } else if (code === KEY.home) {
    await requestLG(LG.launch, { id: LG.homeApp });
  } else if (P.LG_BUTTON[code]) {
    await buttonLG(P.LG_BUTTON[code]);
  }
}

const press = (code) => (state.target === 'lg' ? pressLG(code) : run(command.key(code)));
const connectActive = () => (state.target === 'lg' ? connectLG() : connectGoogle());

function sendText() {
  const field = $('#text');
  const text = field.value;
  if (!text) return;
  if (state.target === 'lg') {
    requestLG(LG.insertText, { text, replace: 0 });
  } else {
    const line = command.text(text);
    if (!line) return notice('The TV can only receive plain letters, numbers and symbols.');
    run(line);
  }
  field.value = '';
  field.blur();
  renderText();
}

function searchText() {
  const field = $('#text');
  if (!field.value.trim()) return;
  run(command.search(field.value));
  field.value = '';
  field.blur();
  renderText();
}

async function castLink() {
  const field = $('#link');
  const text = field.value.trim();
  const action = P.classify(text);
  if (!action) return notice('Enter a full link starting with http or https.');
  field.blur();
  const status = $('#castStatus');
  status.textContent = 'Sending…';
  let target = null;
  if (action.pkg) target = P.linkPackage(action.pkg, (await run('pm list packages -e')) || '');
  const output = await run(command.link(new URL(text).href, target, action.type));
  status.textContent = output === null ? "Couldn't reach the TV." : /Error:/.test(output) ? "The TV has no app that can open this link." : 'Opened on TV';
}

function renderBanner() {
  const tv = state[state.target];
  const banner = $('#banner');
  const text = {
    idle: `Connecting to your ${state.target === 'lg' ? 'LG TV' : 'Google TV'}…`,
    connecting: `Connecting to your ${state.target === 'lg' ? 'LG TV' : 'Google TV'}…`,
    approve: state.target === 'lg' ? 'On your LG TV, choose Accept for LG Remote App.' : 'On your TV, check Always allow, then choose Allow.',
    failed: tv.message,
  }[tv.link];
  banner.hidden = tv.link === 'connected';
  $('#bannerText').textContent = text || '';
  $('#retry').hidden = tv.link !== 'failed';
}

function tile(name, onClick) {
  const button = document.createElement('button');
  button.className = 'tile';
  const letter = document.createElement('span');
  letter.textContent = [...name][0] || '?';
  const label = document.createElement('span');
  label.className = 'name';
  label.textContent = name;
  button.append(letter, label);
  button.addEventListener('click', onClick);
  return button;
}

function renderApps() {
  const isLG = state.target === 'lg';
  const tv = state[state.target];
  const inputs = $('#inputs');
  const grid = $('#appGrid');
  inputs.replaceChildren(...(isLG ? tv.inputs : []).map((input) => {
    const button = document.createElement('button');
    button.className = 'chip';
    button.textContent = input.id === LG.googleInput ? 'Google TV' : input.name;
    button.style.opacity = input.connected ? 1 : 0.55;
    button.addEventListener('click', () => requestLG(LG.switchInput, { inputId: input.id }));
    return button;
  }));
  inputs.hidden = !isLG || !tv.inputs.length;
  grid.replaceChildren(...tv.apps.map((app) => tile(app.name, () => {
    if (isLG) requestLG(LG.launch, { id: app.id });
    else { const line = command.launch(app.id); if (line) run(line); }
  })));
  $('#appsEmpty').hidden = tv.apps.length > 0;
}

function renderActions() {
  const list = isLGActions();
  $('#actions').replaceChildren(...list.map(([title, run_]) => {
    const button = document.createElement('button');
    button.className = 'row-btn';
    button.textContent = title;
    button.addEventListener('click', run_);
    return button;
  }));
}

function isLGActions() {
  if (state.target === 'lg') {
    return [
      ['Switch to Google TV', () => requestLG(LG.switchInput, { inputId: LG.googleInput })],
      ['Turn on through Google TV box', wakeLG],
      ['LG settings', () => buttonLG('MENU')],
    ];
  }
  return [
    ['Home controls and profiles', () => run(command.quickPanel)],
    ['Movie and TV library', () => run(command.library)],
    ['TV settings and ambient mode', () => run(command.settings)],
    ['Fix audio sync', () => run(command.syncTuner)],
  ];
}

const SETUP = [['Camera', 0, 0], ['Microphone', 1, 0], ['Show over other apps', 2, 1], ['App usage access', 3, 2], ['Keep running in background', 4, 3]];

function renderAway() {
  const granted = JSON.parse(Native.granted());
  $('#setup').replaceChildren(...SETUP.map(([title, at, action]) => {
    const row = document.createElement('div');
    row.className = 'setup-row';
    const label = document.createElement('span');
    label.textContent = title;
    const button = document.createElement('button');
    button.textContent = granted[at] === 0 ? 'On' : 'Turn on';
    button.disabled = granted[at] === 0;
    button.addEventListener('click', () => Native.setup(action));
    row.append(label, button);
    return row;
  }));
  $('#tailIp').textContent = Native.tailscale() || 'Not connected. Open Tailscale on this Echo.';
}

function renderText() {
  const empty = !$('#text').value;
  $('#send').disabled = empty;
  $('#search').disabled = empty;
}

function render() {
  const isLG = state.target === 'lg';
  if (isLG && state.tab === 'cast') state.tab = 'remote';
  document.querySelectorAll('[data-target]').forEach((b) => b.setAttribute('aria-pressed', b.dataset.target === state.target));
  document.querySelectorAll('[data-tab]').forEach((b) => b.setAttribute('aria-pressed', b.dataset.tab === state.tab));
  document.querySelectorAll('.panel').forEach((p) => p.classList.toggle('on', p.id === state.tab));
  $('[data-tab=cast]').hidden = isLG;
  $('#search').hidden = isLG;
  $('#slotA').setAttribute('aria-label', isLG ? 'Switch to Google TV' : 'Quick panel');
  $('#slotA use').setAttribute('href', isLG ? '#i-input' : '#i-grid');
  $('#slotB').setAttribute('aria-label', isLG ? 'LG settings' : 'TV settings');
  $('#address').value = state[state.target].host;
  const danger = $('#danger');
  danger.textContent = isLG ? 'Forget LG pairing' : 'Restart TV';
  delete danger.dataset.armed;
  renderBanner();
  renderApps();
  renderActions();
  renderText();
  renderAway();
}

document.querySelectorAll('[data-key]').forEach((b) => b.addEventListener('click', () => press(KEY[b.dataset.key])));
document.querySelectorAll('[data-target]').forEach((b) => b.addEventListener('click', () => {
  state.target = b.dataset.target;
  store.set('tvTarget', state.target);
  render();
  connectActive();
}));
document.querySelectorAll('[data-tab]').forEach((b) => b.addEventListener('click', () => {
  state.tab = b.dataset.tab;
  render();
}));
$('#slotA').addEventListener('click', () => (state.target === 'lg' ? requestLG(LG.switchInput, { inputId: LG.googleInput }) : run(command.quickPanel)));
$('#slotB').addEventListener('click', () => (state.target === 'lg' ? buttonLG('MENU') : run(command.settings)));
$('#retry').addEventListener('click', connectActive);
$('#text').addEventListener('input', renderText);
$('#text').addEventListener('keydown', (e) => { if (e.key === 'Enter') sendText(); });
$('#send').addEventListener('click', sendText);
$('#search').addEventListener('click', searchText);
$('#castBtn').addEventListener('click', castLink);
$('#link').addEventListener('keydown', (e) => { if (e.key === 'Enter') castLink(); });
$('#refresh').addEventListener('click', () => (state.target === 'lg' ? refreshLG() : refreshGoogle()));
$('#save').addEventListener('click', () => {
  const host = $('#address').value.trim();
  if (!P.isPrivateIPv4(host)) return notice('Enter an address like 192.168.1.20.');
  $('#address').blur();
  const tv = state[state.target];
  tv.host = host;
  tv.apps = [];
  store.set(state.target === 'lg' ? 'lgHost' : 'tvHost', host);
  if (state.target === 'lg') { tv.inputs = []; lg.drop(); connectLG(); } else { adb.drop(); connectGoogle(); }
  renderApps();
});

// Both of these are hard to undo, so the first tap only arms the button.
$('#danger').addEventListener('click', (event) => {
  const button = event.currentTarget;
  if (!button.dataset.armed) {
    button.dataset.armed = '1';
    button.textContent = 'Tap again to confirm';
    setTimeout(() => { if (button.dataset.armed) render(); }, 4000);
    return;
  }
  delete button.dataset.armed;
  if (state.target === 'lg') {
    lg.forget(state.lg.host);
    state.lg.apps = [];
    state.lg.inputs = [];
    connectLG();
  } else {
    adb.reboot();
    adb.drop();
    setLink(state.google, 'failed', 'TV is restarting. Tap Retry in a minute.');
  }
  render();
});
$('#pair').addEventListener('click', () => {
  const code = String(crypto.getRandomValues(new Uint32Array(1))[0] % 1000000).padStart(6, '0');
  store.set('pairWindow', JSON.stringify({ code, until: Date.now() + 300000, tries: 0 }));
  $('#pairCode').textContent = code;
});
document.addEventListener('visibilitychange', () => {
  if (document.hidden) return;
  renderAway();
  connectActive();
});

render();
connectActive();
