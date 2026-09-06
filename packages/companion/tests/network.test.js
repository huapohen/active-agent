'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {EventEmitter} = require('node:events');
const {PassThrough} = require('node:stream');
const {publicAddress, resolveTarget, pinnedRequest} = require('../network');

test('remote DNS cannot expand an allowed origin into private, metadata or special addresses', async () => {
  for (const address of ['0.0.0.0', '10.1.2.3', '127.0.0.2', '100.100.100.200', '169.254.169.254', '172.31.0.1', '192.168.0.1', '192.0.2.1', '198.18.0.1', '203.0.113.1', '224.0.0.1', '::', '::1', '::ffff:127.0.0.1', 'fc00::1', 'fe80::1', 'ff02::1', '2001:db8::1', '2002:c0a8:1::1', '3fff::1']) assert.equal(publicAddress(address), false, address);
  assert.equal(publicAddress('8.8.8.8'), true);
  assert.equal(publicAddress('2606:4700:4700::1111'), true);
  await assert.rejects(resolveTarget(new URL('https://allowlisted.example/'), async () => [{address: '8.8.8.8', family: 4}, {address: '127.0.0.1', family: 4}]), {code: 'network_address_denied'});
  await assert.rejects(resolveTarget(new URL('http://169.254.169.254/')), {code: 'network_address_denied'});
  assert.deepEqual(await resolveTarget(new URL('http://localhost/'), async () => { throw Error('localhost must not use DNS'); }), {address: '127.0.0.1', family: 4});
});

test('HTTP transport pins the checked address without a second DNS lookup and preserves original host', async () => {
  let lookups = 0, connectionChecks = 0;
  const dependencies = {
    lookup: async () => [{address: ++lookups === 1 ? '8.8.8.8' : '127.0.0.1', family: 4}],
    request: (url, options, callback) => {
      assert.equal(url.hostname, 'allowlisted.example');
      assert.equal(options.headers.host, 'allowlisted.example');
      assert.equal(options.headers['proxy-authorization'], undefined);
      for (const all of [false, true]) options.lookup(url.hostname, {all}, (error, address, family) => {
        assert.equal(error, null);
        assert.deepEqual(address, all ? [{address: '8.8.8.8', family: 4}] : '8.8.8.8');
        if (!all) assert.equal(family, 4);
        connectionChecks++;
      });
      const request = new EventEmitter();
      request.destroy = () => {};
      request.end = () => queueMicrotask(() => {
        const response = new PassThrough();
        response.statusCode = 200;
        response.headers = {'content-type': 'text/plain', 'set-cookie': ['a=1; Path=/', 'b=2; Path=/'], 'transfer-encoding': 'chunked'};
        callback(response); response.end('synthetic response');
      });
      return request;
    },
  };
  const result = await pinnedRequest({url: new URL('https://allowlisted.example/'), method: 'GET', headers: {'proxy-authorization': 'synthetic'}, timeoutMs: 1000, authorize: () => {}}, dependencies);
  assert.equal(lookups, 1); assert.equal(connectionChecks, 2);
  assert.equal(result.body.toString(), 'synthetic response');
  assert.equal(result.headers['set-cookie'], 'a=1; Path=/\nb=2; Path=/');
  assert.equal(result.headers['transfer-encoding'], undefined);
});

test('a cancelled or stalled DNS lookup never opens a connection', async () => {
  let connections = 0;
  await assert.rejects(pinnedRequest({url: new URL('https://allowlisted.example/'), method: 'GET', headers: {}, timeoutMs: 30, authorize: () => {}}, {
    lookup: () => new Promise(() => {}), request: () => { connections++; },
  }), {code: 'network_timeout'});
  assert.equal(connections, 0);
});
