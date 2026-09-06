'use strict';

const dns = require('node:dns').promises;
const http = require('node:http');
const https = require('node:https');
const net = require('node:net');
const zlib = require('node:zlib');
const {problem} = require('./policy');

// Conservative public-unicast policy. Private networks are never enabled by
// adding a DNS name to the origin allowlist. Literal loopback is an intentional
// exception for local demos, and still has to pass the exact origin policy.
function publicAddress(address) {
  if (net.isIP(address) === 4) {
    const [a, b, c] = address.split('.').map(Number);
    return !(a === 0 || a === 10 || a === 127 || a >= 224 ||
      (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && (b === 168 || (b === 0 && (c === 0 || c === 2)) || (b === 88 && c === 99))) ||
      (a === 198 && (b === 18 || b === 19 || (b === 51 && c === 100))) ||
      (a === 203 && b === 0 && c === 113));
  }
  if (net.isIP(address) !== 6) return false;
  const normalized = new URL(`http://[${address}]/`).hostname.slice(1, -1);
  const parts = normalized.split(':');
  const first = parseInt(parts[0] || '0', 16), second = parseInt(parts[1] || '0', 16);
  return first >= 0x2000 && first <= 0x3fff &&
    !(first === 0x2001 && (second < 0x200 || second === 0xdb8)) && // Special-purpose protocols and documentation.
    first !== 0x2002 && first !== 0x3fff; // 6to4 and documentation; no mapped/private addresses.
}

async function resolveTarget(url, lookup = dns.lookup) {
  const hostname = url.hostname.replace(/^\[|\]$/g, '');
  if (hostname === 'localhost' || hostname === '127.0.0.1') return {address: '127.0.0.1', family: 4};
  if (hostname === '::1') return {address: '::1', family: 6};
  const literal = net.isIP(hostname);
  const records = literal ? [{address: hostname, family: literal}] : await lookup(hostname, {all: true, verbatim: true});
  if (!records.length || records.some(record => !publicAddress(record.address)))
    throw problem(403, 'network_address_denied', 'Remote origins must resolve exclusively to public unicast addresses');
  return records[0];
}

async function pinnedRequest({url, method, headers, body, timeoutMs, signal, authorize}, dependencies = {}) {
  const limit = 16 * 1024 * 1024;
  if (body && body.length > 1024 * 1024) throw problem(413, 'upstream_body_too_large', 'Page request body exceeds one MiB');
  const controller = new AbortController();
  const abort = () => controller.abort();
  const timer = setTimeout(abort, timeoutMs);
  signal?.addEventListener('abort', abort, {once: true});
  if (signal?.aborted) abort();
  try {
    const target = await Promise.race([
      resolveTarget(url, dependencies.lookup),
      new Promise((_, reject) => {
        const failed = () => reject(problem(408, 'network_timeout', 'Page network request was cancelled or timed out'));
        if (controller.signal.aborted) failed(); else controller.signal.addEventListener('abort', failed, {once: true});
      }),
    ]);
    if (controller.signal.aborted) throw problem(408, 'network_timeout', 'Page network request was cancelled or timed out');
    const outgoing = {...headers, host: url.host, 'accept-encoding': 'gzip, deflate, br'};
    for (const name of ['connection', 'transfer-encoding', 'proxy-authorization', 'proxy-connection', 'upgrade', 'expect', 'content-length']) delete outgoing[name];
    if (body) outgoing['content-length'] = String(body.length);
    return await new Promise((resolve, reject) => {
      const transport = dependencies.request ?? (url.protocol === 'https:' ? https.request : http.request);
      // Host and TLS servername remain the original hostname. The socket uses
      // only this already-checked address; DNS is not consulted a second time.
      const request = transport(url, {method, headers: outgoing, agent: false, signal: controller.signal,
        autoSelectFamily: false,
        lookup: (_hostname, options, callback) => callback(null, ...(options?.all ? [[target]] : [target.address, target.family])),
      }, response => {
        const status = response.statusCode;
        try {
          if (status >= 300 && status < 400 && response.headers.location) authorize(new URL(response.headers.location, url).href);
          if (Number(response.headers['content-length']) > limit) throw problem(413, 'upstream_too_large', 'Page response exceeds 16 MiB');
        } catch (error) { response.destroy(); request.destroy(); reject(error); return; }
        let bytes = 0; const chunks = [];
        response.on('data', chunk => {
          bytes += chunk.length;
          if (bytes > limit) { response.destroy(); request.destroy(); reject(problem(413, 'upstream_too_large', 'Page response exceeds 16 MiB')); }
          else chunks.push(chunk);
        });
        response.on('error', reject);
        response.on('end', () => {
          let content = Buffer.concat(chunks);
          try {
            const decode = {gzip: zlib.gunzipSync, deflate: zlib.inflateSync, br: zlib.brotliDecompressSync};
            const encodings = (response.headers['content-encoding'] || '').split(',').map(value => value.trim().toLowerCase()).filter(value => value && value !== 'identity');
            for (const encoding of encodings.reverse()) {
              if (!decode[encoding]) throw problem(422, 'content_encoding_denied', 'Unsupported page response encoding');
              content = decode[encoding](content, {maxOutputLength: limit});
            }
          } catch (error) { reject(error); return; }
          const incoming = {};
          for (const [name, value] of Object.entries(response.headers)) {
            if (value !== undefined && !['connection', 'transfer-encoding', 'keep-alive', 'upgrade', 'content-encoding', 'content-length'].includes(name)) incoming[name] = Array.isArray(value) ? value.join('\n') : value;
          }
          // Playwright's intercepted response body must already be decoded.
          incoming['content-length'] = String(content.length);
          resolve({status, headers: incoming, body: content});
        });
      });
      request.on('error', reject);
      request.end(body ?? undefined);
    });
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', abort);
  }
}

module.exports = {publicAddress, resolveTarget, pinnedRequest};
