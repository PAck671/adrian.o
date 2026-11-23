// TV protocol helpers with no page or device access, so test_proto.js can run them in Node.
const Proto = (() => {
  const CMD = { CNXN: 0x4e584e43, AUTH: 0x48545541, OPEN: 0x4e45504f, OKAY: 0x59414b4f, CLSE: 0x45534c43, WRTE: 0x45545257 };
  const KEY = { home: 3, back: 4, up: 19, down: 20, left: 21, right: 22, ok: 23, volumeUp: 24, volumeDown: 25, power: 26, playPause: 85, rewind: 89, forward: 90, mute: 164, wakeup: 224 };
  const LG_BUTTON = { 19: 'UP', 20: 'DOWN', 21: 'LEFT', 22: 'RIGHT', 23: 'ENTER', 4: 'BACK', 24: 'VOLUMEUP', 25: 'VOLUMEDOWN', 164: 'MUTE', 89: 'REWIND', 90: 'FASTFORWARD' };
  const SHA1_PREFIX = [0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14];
  const utf8 = (text) => new TextEncoder().encode(text);

  const b64 = (bytes) => {
    let s = '';
    for (let i = 0; i < bytes.length; i += 8192) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 8192));
    return btoa(s);
  };
  const unb64 = (text) => Uint8Array.from(atob(text.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));

  function bytesToBig(bytes) {
    let hex = '';
    for (const b of bytes) hex += b.toString(16).padStart(2, '0');
    return BigInt('0x' + hex);
  }

  function bigToBytes(value, length) {
    const out = new Uint8Array(length);
    for (let i = length - 1; i >= 0; i--) {
      out[i] = Number(value & 255n);
      value >>= 8n;
    }
    return out;
  }

  function modPow(base, exponent, modulus) {
    let result = 1n;
    base %= modulus;
    while (exponent > 0n) {
      if (exponent & 1n) result = (result * base) % modulus;
      base = (base * base) % modulus;
      exponent >>= 1n;
    }
    return result;
  }

  function adbPacket(command, arg0, arg1, payload = new Uint8Array(0)) {
    const out = new Uint8Array(24 + payload.length);
    const view = new DataView(out.buffer);
    let sum = 0;
    for (const b of payload) sum = (sum + b) >>> 0;
    [command, arg0, arg1, payload.length, sum, ~command >>> 0].forEach((v, i) => view.setUint32(i * 4, v >>> 0, true));
    out.set(payload, 24);
    return out;
  }

  // The base64 layout adbd expects for a 2048-bit RSA public key.
  function androidPublicKey(n, exponent) {
    const le = bigToBytes(n, 256).reverse();
    const n0 = new DataView(le.buffer).getUint32(0, true);
    let inverse = n0;
    for (let i = 0; i < 5; i++) inverse = Math.imul(inverse, (2 - Math.imul(n0, inverse)) | 0);
    const out = new Uint8Array(524);
    const view = new DataView(out.buffer);
    view.setUint32(0, 64, true);
    view.setUint32(4, -inverse >>> 0, true);
    out.set(le, 8);
    out.set(bigToBytes((1n << 4096n) % n, 256).reverse(), 264);
    view.setUint32(520, exponent, true);
    return out;
  }

  // ADB's token is already the digest, so it is signed as-is with SHA-1 PKCS#1 padding.
  function adbSign(token, n, d) {
    if (token.length !== 20) throw new Error('bad ADB token');
    const block = new Uint8Array(256).fill(0xff);
    const tail = [...SHA1_PREFIX, ...token];
    block[0] = 0;
    block[1] = 1;
    block[255 - tail.length] = 0;
    block.set(tail, 256 - tail.length);
    return bigToBytes(modPow(bytesToBig(block), d, n), 256);
  }

  function wsFrame(data, opcode, mask) {
    const body = typeof data === 'string' ? utf8(data) : data;
    if (body.length >= 65536) throw new Error('frame too large');
    const head = body.length < 126
      ? [0x80 | opcode, 0x80 | body.length]
      : [0x80 | opcode, 0xfe, body.length >> 8, body.length & 255];
    const out = new Uint8Array(head.length + 4 + body.length);
    out.set(head);
    out.set(mask, head.length);
    body.forEach((b, i) => { out[head.length + 4 + i] = b ^ mask[i % 4]; });
    return out;
  }

  // Server frames are unmasked and can be larger than a client's.
  function wsServerFrame(data, opcode) {
    const body = typeof data === 'string' ? utf8(data) : data;
    const size = body.length;
    const head = size < 126 ? [0x80 | opcode, size]
      : size < 65536 ? [0x80 | opcode, 126, size >> 8, size & 255]
        : [0x80 | opcode, 127, 0, 0, 0, 0, (size >>> 24) & 255, (size >> 16) & 255, (size >> 8) & 255, size & 255];
    const out = new Uint8Array(head.length + size);
    out.set(head);
    out.set(body, head.length);
    return out;
  }

  function concat(parts) {
    const out = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
    let at = 0;
    for (const part of parts) { out.set(part, at); at += part.length; }
    return out;
  }

  const quote = (text) => "'" + text.replace(/'/g, "'\\''") + "'";
  const oneLine = (text) => text.replace(/[\r\n]+/g, ' ').trim();
  const isComponent = (text) => /^[A-Za-z0-9_.]+\/[A-Za-z0-9_.$]+$/.test(text);

  function isPrivateIPv4(text) {
    const parts = text.split('.');
    if (parts.length !== 4 || !parts.every((p) => /^\d{1,3}$/.test(p) && +p <= 255)) return false;
    const [a, b] = parts.map(Number);
    return a === 10 || (a === 192 && b === 168) || (a === 172 && b >= 16 && b <= 31);
  }

  const command = {
    key: (code) => `cmd input keyevent ${code}`,
    launch: (component) => (isComponent(component) ? `am start -n ${quote(component)}` : null),
    search: (query) => `am start -a android.search.action.GLOBAL_SEARCH --es query ${quote(oneLine(query))}`,
    // shortcut: Android's `input text` only types ASCII, upgrade with a helper IME if accents or emoji are needed.
    text(text) {
      const ascii = oneLine(text).replace(/[^\x20-\x7e]/g, '');
      return ascii ? `cmd input text ${quote(ascii.replace(/ /g, '%s'))}` : null;
    },
    link(url, target, type) {
      let line = `am start -a android.intent.action.VIEW -d ${quote(url)}`;
      if (type) line += ` -t ${quote(type)}`;
      if (target) line += ` ${quote(target)}`;
      return line;
    },
    quickPanel: 'cmd input keyevent --longpress 3',
    listApps: 'cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LEANBACK_LAUNCHER',
    settings: 'am start -a android.settings.SETTINGS',
    library: 'am start -n com.google.android.videos/.tv.presenter.activity.TvLauncherActivity',
    syncTuner: 'am start -a com.google.android.chromecast.chromecastservice.sliceprovider.SHOW_AUDIO_AV_SYNC_TUNING_WARNING -n com.droidlogic.tv.settings/.sliceprovider.dialog.AVSyncTuningActivity',
  };

  const NAMES = {
    'com.amazon.amazonvideo.livingroom': 'Prime Video', 'com.apple.atve.androidtv.appletv': 'Apple TV', 'com.cbs.ott': 'Paramount+',
    'com.disney.disneyplus': 'Disney+', 'com.espn.score_center': 'ESPN', 'com.goodtoolapps.zeus': 'Zeus',
    'com.google.android.videos': 'Google TV Library', 'com.google.android.youtube.tv': 'YouTube',
    'com.google.android.youtube.tvunplugged': 'YouTube TV', 'com.hulu.livingroomplus': 'Hulu', 'com.nbaimd.gametime.nba2011': 'NBA',
    'com.netflix.ninja': 'Netflix', 'com.peacocktv.peacockandroid': 'Peacock', 'com.playstation.remoteplay.tv': 'PS Remote Play',
    'com.spotify.tv.android': 'Spotify', 'com.tubitv': 'Tubi', 'com.wbd.stream': 'HBO Max', 'tv.pluto.android': 'Pluto TV',
    'org.smarttube.stable': 'SmartTube', 'org.localsend.localsend_app': 'LocalSend',
  };
  const HIDDEN = new Set(['com.android.tv.settings', 'com.android.vending']);
  const MEDIA = {
    mp4: 'video/mp4', m4v: 'video/mp4', webm: 'video/webm', mkv: 'video/x-matroska', m3u8: 'application/x-mpegURL', mpd: 'application/dash+xml',
    mp3: 'audio/mpeg', m4a: 'audio/mp4', aac: 'audio/aac', wav: 'audio/wav', flac: 'audio/flac', ogg: 'audio/ogg',
    jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', gif: 'image/gif', webp: 'image/webp',
  };

  function parseApps(output) {
    const seen = new Set();
    const apps = [];
    for (const raw of output.split(/\r?\n/)) {
      const line = raw.trim();
      if (!isComponent(line)) continue;
      const pkg = line.split('/')[0];
      if (HIDDEN.has(pkg) || seen.has(pkg)) continue;
      seen.add(pkg);
      const last = pkg.split('.').pop();
      apps.push({ id: line, name: NAMES[pkg] || last[0].toUpperCase() + last.slice(1) });
    }
    return apps.sort((x, y) => x.name.localeCompare(y.name));
  }

  function classify(text) {
    let url;
    try { url = new URL(text); } catch { return null; }
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
    const host = url.hostname.toLowerCase();
    if (host === 'youtu.be' || host === 'youtube.com' || host.endsWith('.youtube.com')) return { pkg: 'com.google.android.youtube.tv' };
    if (host === 'netflix.com' || host.endsWith('.netflix.com')) return { pkg: 'com.netflix.ninja' };
    const ext = url.pathname.split('.').pop().toLowerCase();
    return MEDIA[ext] ? { type: MEDIA[ext] } : {};
  }

  function linkPackage(pkg, enabled) {
    const installed = new Set(enabled.split(/\r?\n/).map((l) => l.replace('package:', '').trim()));
    if (installed.has(pkg)) return pkg;
    return pkg === 'com.google.android.youtube.tv' && installed.has('org.smarttube.stable') ? 'org.smarttube.stable' : null;
  }

  // The TV hands back a socket address, which must stay on the same TV. The caller always uses the encrypted port.
  function pointerPath(raw, host) {
    let url;
    try { url = new URL(raw); } catch { return null; }
    return url.hostname === host && url.pathname.length > 1 ? url.pathname + url.search : null;
  }

  // LG's published test-app manifest, the standard way third-party remotes pair. The owner still approves on the TV.
  const SIGNATURE = 'eyJhbGdvcml0aG0iOiJSU0EtU0hBMjU2Iiwia2V5SWQiOiJ0ZXN0LXNpZ25pbmctY2VydCIsInNpZ25hdHVyZVZlcnNpb24iOjF9.hrVRgjCwXVvE2OOSpDZ58hR+59aFNwYDyjQgKk3auukd7pcegmE2CzPCa0bJ0ZsRAcKkCTJrWo5iDzNhMBWRyaMOv5zWSrthlf7G128qvIlpMT0YNY+n/FaOHE73uLrS/g7swl3/qH/BGFG2Hu4RlL48eb3lLKqTt2xKHdCs6Cd4RMfJPYnzgvI4BNrFUKsjkcu+WD4OO2A27Pq1n50cMchmcaXadJhGrOqH5YmHdOCj5NSHzJYrsW0HPlpuAx/ECMeIZYDh6RMqaFM2DXzdKX9NmmyqzJ3o/0lkk/N97gfVRLW5hA29yeAwaCViZNCP8iC9aO0q9fQojoa7NQnAtw==';

  function lgRegistration(clientKey) {
    const payload = {
      forcePairing: false,
      pairingType: 'PROMPT',
      manifest: {
        appVersion: '1.1',
        manifestVersion: 1,
        permissions: ['LAUNCH', 'LAUNCH_WEBAPP', 'APP_TO_APP', 'CLOSE', 'TEST_OPEN', 'TEST_PROTECTED', 'CONTROL_AUDIO', 'CONTROL_DISPLAY', 'CONTROL_INPUT_JOYSTICK', 'CONTROL_INPUT_MEDIA_RECORDING', 'CONTROL_INPUT_MEDIA_PLAYBACK', 'CONTROL_INPUT_TV', 'CONTROL_POWER', 'CONTROL_TV_SCREEN', 'READ_APP_STATUS', 'READ_CURRENT_CHANNEL', 'READ_INPUT_DEVICE_LIST', 'READ_NETWORK_STATE', 'READ_RUNNING_APPS', 'READ_TV_CHANNEL_LIST', 'WRITE_NOTIFICATION_TOAST', 'READ_POWER_STATE', 'READ_COUNTRY_INFO', 'CONTROL_INPUT_TEXT', 'CONTROL_MOUSE_AND_KEYBOARD', 'READ_INSTALLED_APPS', 'READ_SETTINGS'],
        signatures: [{ signature: SIGNATURE, signatureVersion: 1 }],
        signed: {
          appId: 'com.lge.test',
          created: '20140509',
          localizedAppNames: { '': 'LG Remote App', 'ko-KR': '리모컨 앱', 'zxx-XX': 'ЛГ Rэмotэ AПП' },
          localizedVendorNames: { '': 'LG Electronics' },
          permissions: ['TEST_SECURE', 'CONTROL_INPUT_TEXT', 'CONTROL_MOUSE_AND_KEYBOARD', 'READ_INSTALLED_APPS', 'READ_LGE_SDX', 'READ_NOTIFICATIONS', 'SEARCH', 'WRITE_SETTINGS', 'WRITE_NOTIFICATION_ALERT', 'CONTROL_POWER', 'READ_CURRENT_CHANNEL', 'READ_RUNNING_APPS', 'READ_UPDATE_INFO', 'UPDATE_FROM_REMOTE_APP', 'READ_LGE_TV_INPUT_EVENTS', 'READ_TV_CURRENT_TIME'],
          serial: '2f930e2d2cfe083771f68e4fe7bb07',
          vendorId: 'com.lge',
        },
      },
    };
    if (clientKey) payload['client-key'] = clientKey;
    return payload;
  }

  return { CMD, KEY, LG_BUTTON, utf8, b64, unb64, bytesToBig, bigToBytes, adbPacket, androidPublicKey, adbSign, wsFrame, wsServerFrame, concat, quote, isPrivateIPv4, command, parseApps, classify, linkPackage, pointerPath, lgRegistration };
})();
if (typeof module !== 'undefined') module.exports = Proto;
