'use strict';
// Runs all the time on the Echo: the iPhone's connection, calls, allowed apps and TV viewing.
const HUB_PORT = 8770;
const $ = (query) => document.querySelector(query);
const hosts = () => ({ google: store.get('tvHost') || '192.168.12.183', lg: store.get('lgHost') || '192.168.12.196' });
const parse = (text, fallback) => { try { return JSON.parse(text) ?? fallback; } catch { return fallback; } };
const quiet = (promise) => promise.catch(() => null);
const byName = (x, y) => x.name.localeCompare(y.name);
const once = (fn) => { let running = null; return () => (running ??= fn().finally(() => { running = null; })); };
const ensureAdb = once(async () => { if (!adb.up) await adb.connect(hosts().google, () => {}); });
const ensureLG = once(async () => { if (!lg.up) await lg.connect(hosts().lg, () => {}); });
const toastLG = (message) => ensureLG().then(() => lg.request('ssap://system.notifications/createToast', { message }));
const rules = () => parse(store.get('hubRules'), {});
const SCREENS = ['echo', 'google', 'lg'];

// These stay open so nobody, including the owner, can be locked out of the device or the hub.
const NEVER_BLOCK = {
  echo: (id) => ['com.adriantools.tvcontrol', 'com.android.launcher3', 'com.android.settings', 'com.tailscale.ipn'].includes(id),
  google: (id) => ['com.google.android.apps.tv.launcherx', 'com.android.tv.settings', 'com.android.vending'].includes(id),
  lg: (id) => /^(com\.webos\.|com\.palm\.)|cleanyourtv|webosbrew/i.test(id),
};

function listEcho() {
  const flat = parse(Native.apps(), []);
  const apps = new Map();
  for (let i = 0; i + 1 < flat.length; i += 2) if (!NEVER_BLOCK.echo(flat[i])) apps.set(flat[i], flat[i + 1]);
  return [...apps].map(([id, name]) => ({ id, name })).sort(byName);
}

async function listGoogle() {
  await ensureAdb();
  const apps = P.parseApps(await adb.shell(command.listApps))
    .map((app) => ({ id: app.id.split('/')[0], name: app.name }))
    .filter((app) => !NEVER_BLOCK.google(app.id));
  const known = new Set(apps.map((app) => app.id));
  for (const id of parse(store.get('hubSuspended'), [])) if (!known.has(id)) apps.push({ id, name: id.split('.').pop() });
  return apps.sort(byName);
}

async function listLG() {
  await ensureLG();
  const reply = await lg.request(LG.apps);
  const seen = new Set();
  return (reply.launchPoints || [])
    .filter((p) => typeof p.id === 'string' && typeof p.title === 'string' && !NEVER_BLOCK.lg(p.id) && !seen.has(p.id) && seen.add(p.id))
    .map((p) => ({ id: p.id, name: p.title }))
    .sort(byName);
}

async function sendState(client) {
  const all = rules();
  const [google, tv] = await Promise.all([quiet(listGoogle()), quiet(listLG())]);
  const screen = (id, name, apps) => ({ id, name, online: apps !== null, apps: apps || [], on: !!all[id]?.on, allowed: all[id]?.allowed || [] });
  client.json({ t: 'state', phase: call.phase, screens: [screen('echo', 'Echo', listEcho()), screen('google', 'Google TV', google), screen('lg', 'LG TV', tv)] });
}

// The box can suspend apps itself, so its limit keeps working even if the hub restarts.
async function applyGoogle() {
  const rule = rules().google;
  const apps = await listGoogle();
  const want = rule?.on ? apps.filter((app) => !rule.allowed.includes(app.id)).map((app) => app.id) : [];
  const had = parse(store.get('hubSuspended'), []);
  const add = want.filter((id) => !had.includes(id));
  const remove = had.filter((id) => !want.includes(id));
  if (add.length) await adb.shell(`pm suspend --user 0 ${add.join(' ')}`);
  if (remove.length) await adb.shell(`pm unsuspend --user 0 ${remove.join(' ')}`);
  store.set('hubSuspended', JSON.stringify(want));
}

async function setRule(client, message) {
  const allowed = Array.isArray(message.allowed) ? message.allowed.filter((id) => typeof id === 'string' && id.length <= 200).slice(0, 500) : null;
  if (!SCREENS.includes(message.screen) || !allowed) return;
  const all = rules();
  all[message.screen] = { on: !!message.on, allowed };
  store.set('hubRules', JSON.stringify(all));
  if (message.screen === 'google') {
    try { await applyGoogle(); } catch { client.json({ t: 'note', text: "Saved, but the Google TV box didn't answer. Try again when it's on." }); }
  }
  sendState(client);
}

let echoApps = { at: 0, ids: new Set() };
let lgRetryAt = 0;
let enforcing = false;
let flashTimer;

function flashBlocked() {
  if (call.phase !== 'idle') return;
  clearTimeout(flashTimer);
  $('#ui').hidden = false;
  $('#self').hidden = true;
  $('#badge').hidden = true;
  $('#answer').hidden = true;
  $('#end').hidden = true;
  $('#title').textContent = 'App not allowed';
  $('#sub').textContent = "This app isn't on the allowed list right now.";
  Native.overlay(true);
  flashTimer = setTimeout(() => { if (call.phase === 'idle') { renderCall(); Native.overlay(false); } }, 3000);
}

async function enforce() {
  if (enforcing) return;
  enforcing = true;
  try {
    const all = rules();
    if (all.echo?.on && call.phase === 'idle') {
      if (Date.now() - echoApps.at > 60000) echoApps = { at: Date.now(), ids: new Set(listEcho().map((app) => app.id)) };
      const app = Native.foreground();
      if (echoApps.ids.has(app) && !all.echo.allowed.includes(app)) { Native.home(); flashBlocked(); }
    }
    if (all.lg?.on && Date.now() >= lgRetryAt) {
      try {
        await ensureLG();
        const id = (await lg.request('ssap://com.webos.applicationManager/getForegroundAppInfo')).appId;
        if (id && !NEVER_BLOCK.lg(id) && !all.lg.allowed.includes(id)) {
          await lg.request(LG.launch, { id: LG.homeApp });
          await quiet(toastLG("This app isn't on the allowed list right now."));
        }
      } catch { lgRetryAt = Date.now() + 30000; }
    }
  } finally { enforcing = false; }
}

const call = { phase: 'idle', client: null, media: null, ctx: null, playAt: 0, waiting: false, sentAt: 0, timer: null, ringer: null };

function tone(frequency, seconds) {
  const ctx = new AudioContext();
  const oscillator = ctx.createOscillator();
  const gain = ctx.createGain();
  oscillator.frequency.value = frequency;
  gain.gain.value = 0.25;
  oscillator.connect(gain).connect(ctx.destination);
  oscillator.start();
  oscillator.stop(ctx.currentTime + seconds);
  oscillator.onended = () => ctx.close();
}

function chime() {
  tone(880, 0.18);
  setTimeout(() => tone(1175, 0.28), 200);
}

function renderCall() {
  const ringing = call.phase === 'ringing';
  const live = call.phase === 'live' || call.phase === 'connecting';
  $('#ui').hidden = !ringing && !live;
  $('#self').hidden = !live;
  $('#badge').hidden = !live;
  $('#answer').hidden = !ringing;
  $('#end').hidden = false;
  $('#end').textContent = ringing ? 'Decline' : 'End';
  $('#title').textContent = ringing ? 'Incoming call' : 'On a call';
  $('#sub').textContent = ringing ? 'From the owner\'s iPhone' : 'The camera and microphone are on. Tap End to stop.';
}

function setCall(phase, note = '') {
  call.phase = phase;
  call.client?.json({ t: 'call', phase, note });
  renderCall();
}

async function beginCall(client, mode) {
  if (call.phase !== 'idle') return client.json({ t: 'call', phase: 'busy', note: 'The Echo is already on a call.' });
  clearTimeout(flashTimer);
  call.client = client;
  Native.overlay(true);
  if (mode === 'look') {
    chime();
    return goLive();
  }
  // A call rings first, so the person at the Echo chooses whether to answer.
  setCall('ringing');
  chime();
  call.ringer = setInterval(chime, 2500);
  call.timer = setTimeout(() => endCall('No one answered.'), 45000);
  quiet(toastLG('Incoming call on the Echo.'));
}

async function goLive() {
  clearTimeout(call.timer);
  clearInterval(call.ringer);
  call.phase = 'connecting';
  renderCall();
  const client = call.client;
  let media;
  try {
    media = await navigator.mediaDevices.getUserMedia({
      video: { width: 640, height: 360, frameRate: 12, facingMode: 'user' },
      audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
    });
  } catch {
    return endCall('The Echo camera or mic is off. Check its privacy button and camera shutter.');
  }
  if (call.client !== client) return media.getTracks().forEach((track) => track.stop());
  call.media = media;
  $('#self').srcObject = media;
  setCall('live');
  startAudio();
  videoLoop();
}

function startAudio() {
  const ctx = new AudioContext({ sampleRate: 16000, latencyHint: 'interactive' });
  call.ctx = ctx;
  call.playAt = 0;
  const source = ctx.createMediaStreamSource(call.media);
  // shortcut: ScriptProcessor is deprecated but needs no extra module, move to AudioWorklet if WebView drops it.
  const processor = ctx.createScriptProcessor(1024, 1, 1);
  const silent = ctx.createGain();
  silent.gain.value = 0;
  processor.onaudioprocess = (event) => {
    if (call.phase !== 'live') return;
    const input = event.inputBuffer.getChannelData(0);
    const pcm = new Int16Array(input.length);
    for (let i = 0; i < input.length; i++) pcm[i] = Math.max(-1, Math.min(1, input[i])) * 32767;
    call.client?.binary(2, new Uint8Array(pcm.buffer));
  };
  source.connect(processor);
  processor.connect(silent).connect(ctx.destination);
  ctx.resume();
}

function playAudio(bytes) {
  const ctx = call.ctx;
  const count = bytes.length >> 1;
  if (call.phase !== 'live' || !ctx || !count) return;
  const at = Math.max(ctx.currentTime + 0.04, call.playAt);
  if (at - ctx.currentTime > 0.6) return; // a late packet is dropped so the call doesn't drift behind
  const view = new DataView(bytes.buffer, bytes.byteOffset, count * 2);
  const buffer = ctx.createBuffer(1, count, 16000);
  const out = buffer.getChannelData(0);
  for (let i = 0; i < count; i++) out[i] = view.getInt16(i * 2, true) / 32768;
  const node = ctx.createBufferSource();
  node.buffer = buffer;
  node.connect(ctx.destination);
  node.start(at);
  call.playAt = at + buffer.duration;
}

async function videoLoop() {
  const video = $('#self');
  const canvas = document.createElement('canvas');
  canvas.width = 640;
  canvas.height = 360;
  const context = canvas.getContext('2d');
  while (call.phase === 'live') {
    // The iPhone acknowledges each picture, so a slow connection gets fewer pictures instead of a growing delay.
    if (video.readyState >= 2 && (!call.waiting || Date.now() - call.sentAt > 3000)) {
      context.drawImage(video, 0, 0, 640, 360);
      const blob = await new Promise((done) => canvas.toBlob(done, 'image/jpeg', 0.55));
      if (blob && call.phase === 'live') {
        call.client.binary(1, new Uint8Array(await blob.arrayBuffer()));
        call.waiting = true;
        call.sentAt = Date.now();
      }
    }
    await sleep(70);
  }
}

function endCall(note = '') {
  if (call.phase === 'idle' && !call.client) return;
  clearTimeout(call.timer);
  clearInterval(call.ringer);
  call.media?.getTracks().forEach((track) => track.stop());
  call.ctx?.close();
  const client = call.client;
  Object.assign(call, { phase: 'idle', client: null, media: null, ctx: null, waiting: false });
  $('#self').srcObject = null;
  renderCall();
  Native.overlay(false);
  client?.json({ t: 'call', phase: 'idle', note });
}

const view = { client: null, screen: null, noticeAt: 0 };
const NOTICE = 'This TV screen is being viewed in TV Control.';

async function toJpeg(blob) {
  const bitmap = await createImageBitmap(blob);
  const canvas = document.createElement('canvas');
  canvas.width = 640;
  canvas.height = 360;
  const context = canvas.getContext('2d');
  context.drawImage(bitmap, 0, 0, 640, 360);
  bitmap.close();
  const sample = context.getImageData(0, 0, 640, 360).data;
  let total = 0;
  for (let i = 0; i < sample.length; i += 400) total += sample[i] + sample[i + 1] + sample[i + 2];
  const dark = total / (sample.length / 400) < 6;
  const jpeg = await new Promise((done) => canvas.toBlob(done, 'image/jpeg', 0.6));
  return { bytes: new Uint8Array(await jpeg.arrayBuffer()), dark };
}

async function grabGoogle() {
  await ensureAdb();
  return toJpeg(new Blob([await adb.exec('screencap -p')], { type: 'image/png' }));
}

async function httpGet(host, port, path) {
  const stream = new Stream(host, port, false);
  try {
    await timed(stream.ready, 5000);
    stream.write(P.utf8(`GET ${path} HTTP/1.0\r\nHost: ${host}\r\nConnection: close\r\n\r\n`));
    await timed(new Promise((done) => { stream.onclose = done; }), 8000);
  } finally { stream.shut(); }
  const raw = stream.have;
  for (let i = 3; i < raw.length; i++) {
    if (raw[i - 3] === 13 && raw[i - 2] === 10 && raw[i - 1] === 13 && raw[i] === 10) {
      if (!/^HTTP\/1\.[01] 200/.test(String.fromCharCode(...raw.subarray(0, 15)))) throw new Error('http');
      return raw.subarray(i + 1);
    }
  }
  throw new Error('http');
}

async function grabLG() {
  await ensureLG();
  const reply = await lg.request('ssap://tv/executeOneShot', { path: '/tmp/capture.jpg', method: 'DISPLAY', format: 'JPEG', width: 640, height: 360 });
  const url = new URL(reply.imageUri);
  if (url.hostname !== hosts().lg || url.protocol !== 'http:') throw new Error('bad address');
  return toJpeg(new Blob([await httpGet(url.hostname, Number(url.port) || 80, url.pathname + url.search)], { type: 'image/jpeg' }));
}

function stopView() {
  const client = view.client;
  view.client = null;
  view.screen = null;
  return client;
}

async function startView(client, screen) {
  stopView();
  if (!screen) return client.json({ t: 'view', screen: null });
  if (screen !== 'google' && screen !== 'lg') return;
  // No notice on the TV means no viewing, so the people watching always know.
  try { await toastLG(NOTICE); } catch {
    return client.json({ t: 'view', screen: null, error: "Couldn't show the viewing notice on the TV, so viewing stayed off. Is the LG TV on?" });
  }
  view.client = client;
  view.screen = screen;
  view.noticeAt = Date.now();
  client.json({ t: 'view', screen });
  while (view.client === client && view.screen === screen) {
    try {
      if (Date.now() - view.noticeAt > 30000) {
        await toastLG(NOTICE);
        view.noticeAt = Date.now();
      }
      const frame = await (screen === 'google' ? grabGoogle() : grabLG());
      if (view.client !== client || view.screen !== screen) return;
      client.binary(3, frame.bytes);
      client.json({ t: 'viewNote', text: frame.dark ? 'The picture is black. Netflix, HBO Max and other protected apps block screen capture.' : '' });
    } catch {
      if (view.client === client) {
        stopView();
        client.json({ t: 'view', screen: null, error: screen === 'lg' ? "The LG TV didn't share its screen." : "Couldn't capture the Google TV screen." });
      }
      return;
    }
    await sleep(1500);
  }
}

class HubClient extends WS {
  frame(body, opcode) { return P.wsServerFrame(body, opcode); }
  json(value) { this.stream.write(this.frame(P.utf8(JSON.stringify(value)), 1)); }
  binary(kind, bytes) {
    const out = new Uint8Array(bytes.length + 1);
    out[0] = kind;
    out.set(bytes, 1);
    this.stream.write(this.frame(out, 2));
  }
}

const sha256 = async (text) => P.b64(new Uint8Array(await crypto.subtle.digest('SHA-256', P.utf8(text))));

async function authorize(client, message) {
  const deny = (note) => { client.json({ t: 'denied', note }); client.shut(); return false; };
  if (message.t === 'hello' && typeof message.token === 'string') {
    if (!parse(store.get('hubTokens'), []).includes(await sha256(message.token))) return deny('This iPhone needs to pair again.');
    client.json({ t: 'ready' });
    return true;
  }
  if (message.t === 'pair' && typeof message.code === 'string') {
    const window_ = parse(store.get('pairWindow'), null);
    if (!window_ || Date.now() > window_.until) return deny('On the Echo, open TV Control, then Away, and tap Pair iPhone.');
    if (message.code !== window_.code) {
      window_.tries += 1;
      if (window_.tries >= 5) store.del('pairWindow');
      else store.set('pairWindow', JSON.stringify(window_));
      return deny('That code is wrong.');
    }
    store.del('pairWindow');
    const token = P.b64(randomBytes(32));
    store.set('hubTokens', JSON.stringify([...parse(store.get('hubTokens'), []), await sha256(token)]));
    client.json({ t: 'paired', token });
    return true;
  }
  return deny('This iPhone needs to pair again.');
}

async function onMessage(client, text, guard) {
  const message = parse(text, null);
  if (!message) return;
  if (!client.authed) {
    if (client.authing) return;
    client.authing = true;
    client.authed = await authorize(client, message);
    client.authing = false;
    if (client.authed) clearTimeout(guard);
    return;
  }
  if (message.t === 'ack') call.waiting = false;
  else if (message.t === 'state') sendState(client);
  else if (message.t === 'rule') setRule(client, message);
  else if (message.t === 'call' && (message.mode === 'call' || message.mode === 'look')) beginCall(client, message.mode);
  else if (message.t === 'hangup' && call.client === client) endCall();
  else if (message.t === 'view') startView(client, message.screen);
}

async function serve(stream) {
  const client = new HubClient(stream);
  const guard = setTimeout(() => stream.shut(), 10000);
  try {
    let head = '';
    while (!head.endsWith('\r\n\r\n')) {
      if (head.length > 4096) throw new Error('bad request');
      head += String.fromCharCode((await stream.read(1))[0]);
    }
    const key = /^sec-websocket-key:\s*(\S+)/im.exec(head)?.[1];
    if (!head.startsWith('GET ') || !key) throw new Error('bad request');
    const digest = await crypto.subtle.digest('SHA-1', P.utf8(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`));
    stream.write(P.utf8(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${P.b64(new Uint8Array(digest))}\r\n\r\n`));
  } catch {
    clearTimeout(guard);
    stream.shut();
    return;
  }
  client.onmessage = (text) => onMessage(client, text, guard);
  client.onbinary = (bytes) => { if (client.authed && call.client === client && bytes[0] === 2) playAudio(bytes.subarray(1)); };
  client.onclose = () => {
    clearTimeout(guard);
    if (call.client === client) endCall();
    if (view.client === client) stopView();
  };
  client.pump();
}

$('#answer').addEventListener('click', () => { if (call.phase === 'ringing') goLive(); });
$('#end').addEventListener('click', () => endCall('The call was ended on the Echo.'));
Net.accept = (id) => serve(new Stream('', 0, false, id));
setInterval(enforce, 3000);
Native.listen(HUB_PORT);
