// Run with: node test_proto.js
const assert = require('assert');
const crypto = require('crypto');
const P = require('./assets/proto.js');

const pair = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const jwk = pair.privateKey.export({ format: 'jwk' });
const n = P.bytesToBig(P.unb64(jwk.n));
const d = P.bytesToBig(P.unb64(jwk.d));

const token = crypto.randomBytes(20);
const signature = P.adbSign(token, n, d);
const opened = crypto.publicDecrypt({ key: pair.publicKey, padding: crypto.constants.RSA_PKCS1_PADDING }, Buffer.from(signature));
assert.strictEqual(opened.subarray(-20).toString('hex'), token.toString('hex'));
assert.strictEqual(opened.subarray(0, 15).toString('hex'), '3021300906052b0e03021a05000414');
assert.throws(() => P.adbSign(new Uint8Array(19), n, d));

const pub = P.androidPublicKey(n, 65537);
const view = new DataView(pub.buffer);
assert.strictEqual(pub.length, 524);
assert.strictEqual(view.getUint32(0, true), 64);
assert.strictEqual(view.getUint32(520, true), 65537);
assert.strictEqual(Math.imul(view.getUint32(4, true), view.getUint32(8, true)), -1);
assert.strictEqual(P.bytesToBig(pub.slice(8, 264).reverse()), n);
assert.strictEqual(P.bytesToBig(pub.slice(264, 520).reverse()), (1n << 4096n) % n);

const packet = P.adbPacket(P.CMD.OPEN, 7, 0, P.utf8('ab'));
const head = new DataView(packet.buffer);
assert.strictEqual(head.getUint32(12, true), 2);
assert.strictEqual(head.getUint32(16, true), 97 + 98);
assert.strictEqual(head.getUint32(20, true), ~P.CMD.OPEN >>> 0);

const mask = [1, 2, 3, 4];
const small = P.wsFrame('hi', 1, mask);
assert.deepStrictEqual([...small.slice(0, 2)], [0x81, 0x82]);
assert.deepStrictEqual([...small.slice(6)], ['h'.charCodeAt(0) ^ 1, 'i'.charCodeAt(0) ^ 2]);
const large = P.wsFrame('x'.repeat(300), 1, mask);
assert.deepStrictEqual([...large.slice(1, 4)], [0xfe, 1, 44]);
assert.throws(() => P.wsFrame(new Uint8Array(65536), 1, mask));

assert.deepStrictEqual([...P.wsServerFrame('hi', 1)], [0x81, 2, 104, 105]);
assert.deepStrictEqual([...P.wsServerFrame(new Uint8Array(300), 2).slice(0, 4)], [0x82, 126, 1, 44]);
assert.deepStrictEqual([...P.wsServerFrame(new Uint8Array(70000), 2).slice(0, 10)], [0x82, 127, 0, 0, 0, 0, 0, 1, 17, 112]);
assert.deepStrictEqual([...P.concat([new Uint8Array([1]), new Uint8Array([2, 3])])], [1, 2, 3]);

assert.strictEqual(P.quote("a'b"), "'a'\\''b'");
assert.strictEqual(P.command.search("x'; reboot\nnow"), "am start -a android.search.action.GLOBAL_SEARCH --es query 'x'\\''; reboot now'");
assert.strictEqual(P.command.text('a b'), "cmd input text 'a%sb'");
assert.strictEqual(P.command.text('é'), null);
assert.strictEqual(P.command.launch('a.b/.C; reboot'), null);

for (const good of ['10.0.0.1', '172.16.0.1', '192.168.12.196']) assert(P.isPrivateIPv4(good));
for (const bad of ['8.8.8.8', '172.32.0.1', '192.168.1', '192.168.1.256', 'tv.local', '']) assert(!P.isPrivateIPv4(bad));

const apps = P.parseApps('com.netflix.ninja/.Main\ncom.netflix.ninja/.Other\ncom.android.vending/.X\nnoise\ncom.foo.bar/.Y\n');
assert.deepStrictEqual(apps.map((a) => a.name), ['Bar', 'Netflix']);

assert.deepStrictEqual(P.classify('https://youtu.be/x'), { pkg: 'com.google.android.youtube.tv' });
assert.deepStrictEqual(P.classify('https://a.com/v.MP4'), { type: 'video/mp4' });
assert.deepStrictEqual(P.classify('https://notyoutube.com/x'), {});
assert.strictEqual(P.classify('file:///etc/passwd'), null);
assert.strictEqual(P.linkPackage('com.google.android.youtube.tv', 'package:org.smarttube.stable\n'), 'org.smarttube.stable');

assert.strictEqual(P.pointerPath('ws://192.168.12.196:3000/resources/a/netinput.pointer.sock', '192.168.12.196'), '/resources/a/netinput.pointer.sock');
assert.strictEqual(P.pointerPath('wss://10.0.0.9:3001/resources/a', '192.168.12.196'), null);
assert.strictEqual(P.lgRegistration('k')['client-key'], 'k');
assert.strictEqual(P.lgRegistration(null)['client-key'], undefined);

console.log('proto tests passed');
