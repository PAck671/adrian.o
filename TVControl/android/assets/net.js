'use strict';
const P = Proto;
const { CMD, KEY, command } = P;
const store = {
  get(k) { try { return localStorage.getItem(k); } catch { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch { /* the app still works, it just asks to pair again */ } },
  del(k) { try { localStorage.removeItem(k); } catch { /* nothing saved to remove */ } },
};
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
const timed = (promise, ms) => Promise.race([promise, new Promise((_, no) => setTimeout(() => no(new Error('timeout')), ms))]);
const randomBytes = (count) => crypto.getRandomValues(new Uint8Array(count));

// Called by the native side as Net.on(id, 'open' | 'data' | 'close', arg).
const Net = {
  next: 1,
  conns: {},
  accept: null,
  on(id, type, arg) {
    // Sockets accepted by the hub's listener are numbered from 1,000,000.
    if (!this.conns[id] && type === 'open' && id >= 1000000) this.accept?.(id);
    this.conns[id]?.[type]?.(arg);
  },
};

class Stream {
  constructor(host, port, tls, accepted) {
    this.id = accepted ?? Net.next++;
    this.have = new Uint8Array(0);
    this.ready = new Promise((ok, no) => { this.onReady = ok; this.onFail = no; });
    this.ready.catch(() => {});
    Net.conns[this.id] = this;
    if (!accepted) Native.open(this.id, host, port, tls);
  }
  open(fingerprint) { this.onReady(fingerprint); }
  data(text) {
    const chunk = P.unb64(text);
    const merged = new Uint8Array(this.have.length + chunk.length);
    merged.set(this.have);
    merged.set(chunk, this.have.length);
    this.have = merged;
    this.pump();
  }
  close() {
    this.closed = true;
    delete Net.conns[this.id];
    this.onFail(new Error('closed'));
    this.pump();
    this.onclose?.();
  }
  pump() {
    const want = this.want;
    if (!want) return;
    if (this.have.length >= want.count) {
      const out = this.have.slice(0, want.count);
      this.have = this.have.slice(want.count);
      this.want = null;
      want.ok(out);
    } else if (this.closed) {
      this.want = null;
      want.no(new Error('closed'));
    }
  }
  read(count) {
    return new Promise((ok, no) => { this.want = { count, ok, no }; this.pump(); });
  }
  write(bytes) { if (!this.closed) Native.write(this.id, P.b64(bytes)); }
  shut() { if (!this.closed) Native.close(this.id); }
}

async function adbKey() {
  let saved = null;
  try { saved = JSON.parse(store.get('adbKey')); } catch { /* make a new key */ }
  if (!saved?.n) {
    const pair = await crypto.subtle.generateKey({ name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign']);
    const jwk = await crypto.subtle.exportKey('jwk', pair.privateKey);
    saved = { n: jwk.n, d: jwk.d };
    store.set('adbKey', JSON.stringify(saved));
  }
  const n = P.bytesToBig(P.unb64(saved.n));
  return { n, d: P.bytesToBig(P.unb64(saved.d)), pub: P.utf8(`${P.b64(P.androidPublicKey(n, 65537))} tvcontrol@echo\0`) };
}

async function readPacket(stream) {
  const head = await stream.read(24);
  const view = new DataView(head.buffer, head.byteOffset, 24);
  const word = (at) => view.getUint32(at, true);
  if (word(20) !== (~word(0) >>> 0) || word(12) > 1048576) throw new Error('bad packet');
  return { command: word(0), arg0: word(4), arg1: word(8), payload: await stream.read(word(12)) };
}

const adb = {
  stream: null,
  nextId: 1,
  shells: {},
  get up() { return !!this.stream; },
  async connect(host, onApprove) {
    const stream = new Stream(host, 5555, false);
    // Leaves time to press Allow on the TV, and unblocks the read if nobody does.
    const watchdog = setTimeout(() => stream.shut(), 60000);
    try {
      await timed(stream.ready, 10000);
      const key = await adbKey();
      stream.write(P.adbPacket(CMD.CNXN, 0x01000001, 256 * 1024, P.utf8('host::\0')));
      let signed = false;
      let offered = false;
      for (;;) {
        const packet = await readPacket(stream);
        if (packet.command === CMD.CNXN) break;
        if (packet.command !== CMD.AUTH || packet.arg0 !== 1) continue;
        if (!signed) {
          signed = true;
          stream.write(P.adbPacket(CMD.AUTH, 2, 0, P.adbSign(packet.payload, key.n, key.d)));
        } else if (!offered) {
          offered = true;
          stream.write(P.adbPacket(CMD.AUTH, 3, 0, key.pub));
          onApprove();
        }
      }
    } catch (error) {
      stream.shut();
      throw error;
    } finally {
      clearTimeout(watchdog);
    }
    this.stream = stream;
    this.pump(stream);
  },
  async pump(stream) {
    try {
      for (;;) this.handle(await readPacket(stream));
    } catch { this.drop(stream); }
  },
  handle(packet) {
    const shell = this.shells[packet.arg1];
    if (!shell) return;
    if (packet.command === CMD.WRTE) {
      shell.out.push(packet.payload);
      this.stream.write(P.adbPacket(CMD.OKAY, packet.arg1, packet.arg0));
    } else if (packet.command === CMD.CLSE) {
      delete this.shells[packet.arg1];
      this.stream.write(P.adbPacket(CMD.CLSE, packet.arg1, packet.arg0));
      const whole = P.concat(shell.out);
      shell.ok(shell.raw ? whole : new TextDecoder().decode(whole));
    }
  },
  exec(line) { return this.shell(line, 'exec', true); },
  shell(line, service = 'shell', raw = false) {
    if (!this.stream) return Promise.reject(new Error('closed'));
    const id = this.nextId++;
    const result = new Promise((ok, no) => { this.shells[id] = { out: [], raw, ok, no }; });
    this.stream.write(P.adbPacket(CMD.OPEN, id, 0, P.utf8(`${service}:${line}\0`)));
    return timed(result, 15000).finally(() => { delete this.shells[id]; });
  },
  reboot() {
    this.stream?.write(P.adbPacket(CMD.OPEN, this.nextId++, 0, P.utf8('reboot:\0')));
  },
  drop(stream = this.stream) {
    if (!stream || stream !== this.stream) return;
    this.stream = null;
    stream.shut();
    const open = this.shells;
    this.shells = {};
    Object.values(open).forEach((shell) => shell.no(new Error('closed')));
  },
};

class WS {
  static async open(host, path) {
    const stream = new Stream(host, 3001, true);
    const socket = new WS(stream);
    try {
      const fingerprint = await timed(stream.ready, 10000);
      // The LG uses a private certificate, so the first one seen is remembered and any change is refused.
      const known = store.get(`cert.${host}`);
      if (known && known !== fingerprint) throw new Error('certificate');
      if (!known) store.set(`cert.${host}`, fingerprint);
      stream.write(P.utf8(`GET ${path} HTTP/1.1\r\nHost: ${host}:3001\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ${P.b64(randomBytes(16))}\r\nSec-WebSocket-Version: 13\r\n\r\n`));
      let head = '';
      while (!head.endsWith('\r\n\r\n')) {
        if (head.length > 8192) throw new Error('bad handshake');
        head += String.fromCharCode((await timed(stream.read(1), 8000))[0]);
      }
      if (!/^HTTP\/1\.1 101/.test(head)) throw new Error('bad handshake');
    } catch (error) {
      stream.shut();
      throw error;
    }
    socket.pump();
    return socket;
  }
  constructor(stream) { this.stream = stream; }
  frame(body, opcode) { return P.wsFrame(body, opcode, randomBytes(4)); }
  send(text) { this.stream.write(this.frame(text, 1)); }
  shut() { this.stream.shut(); }
  async pump() {
    let parts = [];
    let kind = 1;
    try {
      for (;;) {
        const [first, second] = await this.stream.read(2);
        const opcode = first & 15;
        let length = second & 127;
        if (length === 126) {
          const b = await this.stream.read(2);
          length = (b[0] << 8) | b[1];
        } else if (length === 127) {
          const b = await this.stream.read(8);
          if (b[0] || b[1] || b[2] || b[3] || b[4]) throw new Error('frame too large');
          length = (b[5] << 16) | (b[6] << 8) | b[7];
        }
        const mask = second & 128 ? await this.stream.read(4) : null;
        const body = await this.stream.read(length);
        if (mask) body.forEach((b, i) => { body[i] = b ^ mask[i % 4]; });
        if (opcode === 8) break;
        if (opcode === 9) { this.stream.write(this.frame(body, 10)); continue; }
        if (opcode === 10) continue;
        if (opcode) kind = opcode;
        parts.push(body);
        if (first & 128) {
          const whole = P.concat(parts);
          parts = [];
          if (kind === 2) this.onbinary?.(whole);
          else this.onmessage?.(new TextDecoder().decode(whole));
        }
      }
    } catch { /* treated as closed below */ }
    this.stream.shut();
    this.onclose?.();
  }
}

const lg = {
  socket: null,
  pointer: null,
  pointerOpening: null,
  host: '',
  nextId: 1,
  waiting: {},
  get up() { return !!this.socket; },
  async connect(host, onPrompt) {
    const socket = await WS.open(host, '/');
    const account = `key.${host}`;
    const saved = store.get(account);
    const registered = new Promise((ok, no) => {
      socket.onclose = () => no(new Error('closed'));
      socket.onmessage = (text) => {
        let reply;
        try { reply = JSON.parse(text); } catch { return; }
        if (reply.id !== 'register_0') return;
        if (reply.type === 'response' && reply.payload?.pairingType === 'PROMPT') onPrompt();
        if (reply.type === 'registered') {
          if (reply.payload?.['client-key']) store.set(account, reply.payload['client-key']);
          ok();
        }
        if (reply.type === 'error') {
          if (saved) store.del(account);
          no(new Error('rejected'));
        }
      };
    });
    socket.send(JSON.stringify({ id: 'register_0', type: 'register', payload: P.lgRegistration(saved) }));
    try {
      await timed(registered, 60000);
    } catch (error) {
      socket.shut();
      throw error;
    }
    this.host = host;
    this.socket = socket;
    socket.onmessage = (text) => this.handle(text);
    socket.onclose = () => this.drop(socket);
  },
  handle(text) {
    let message;
    try { message = JSON.parse(text); } catch { return; }
    const waiter = this.waiting[message.id];
    if (!waiter) return;
    delete this.waiting[message.id];
    if (message.type === 'error') waiter.no(Object.assign(new Error(message.error || 'The LG TV refused that command.'), { refused: true }));
    else waiter.ok(message.payload || {});
  },
  request(uri, payload = {}) {
    if (!this.socket) return Promise.reject(new Error('closed'));
    const id = String(this.nextId++);
    const result = new Promise((ok, no) => { this.waiting[id] = { ok, no }; });
    this.socket.send(JSON.stringify({ id, type: 'request', uri, payload }));
    return timed(result, 10000).finally(() => { delete this.waiting[id]; });
  },
  async button(name) {
    if (!this.pointer) {
      this.pointerOpening ??= this.openPointer().finally(() => { this.pointerOpening = null; });
      await this.pointerOpening;
    }
    if (!this.pointer) throw new Error('closed');
    this.pointer.send(`type:button\nname:${name}\n\n`);
  },
  async openPointer() {
    const reply = await this.request('ssap://com.webos.service.networkinput/getPointerInputSocket');
    const path = P.pointerPath(reply.socketPath || '', this.host);
    if (!path) throw Object.assign(new Error("The LG TV didn't open its remote control channel."), { refused: true });
    const pointer = await WS.open(this.host, path);
    pointer.onclose = () => { if (this.pointer === pointer) this.pointer = null; };
    this.pointer = pointer;
  },
  drop(socket = this.socket) {
    if (!socket || socket !== this.socket) return;
    this.socket = null;
    socket.shut();
    this.pointer?.shut();
    this.pointer = null;
    const open = this.waiting;
    this.waiting = {};
    Object.values(open).forEach((waiter) => waiter.no(new Error('closed')));
  },
  forget(host) {
    this.drop();
    store.del(`key.${host}`);
    store.del(`cert.${host}`);
  },
};

const LG = {
  apps: 'ssap://com.webos.applicationManager/listLaunchPoints',
  inputs: 'ssap://tv/getExternalInputList',
  launch: 'ssap://system.launcher/launch',
  switchInput: 'ssap://tv/switchInput',
  insertText: 'ssap://com.webos.service.ime/insertText',
  turnOff: 'ssap://system/turnOff',
  play: 'ssap://media.controls/play',
  pause: 'ssap://media.controls/pause',
  // The Google TV box reports HDMI-CEC address 3.0.0.0, which is the LG's HDMI 3.
  googleInput: 'HDMI_3',
  // CleanYourTV replaces this app. The TV's HOME key opens LG's separate fullhome app instead.
  homeApp: 'com.webos.app.home',
};

