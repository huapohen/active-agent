'use strict';
const path = require('node:path');

function developmentURL(value) {
  const url = new URL(value);
  if (url.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) || url.username || url.password || url.search || url.hash) throw new Error('Invalid desktop development origin');
  return url.origin;
}
function trustedFrame(frame, origin) {
  if (!frame || frame.parent) return false;
  try { const url = new URL(frame.url); return origin === 'renji://app' ? url.protocol === 'renji:' && url.hostname === 'app' : url.origin === origin; } catch { return false; }
}
function assetPath(base, rawPath) {
  let decoded;
  try { decoded = decodeURIComponent(rawPath); } catch { throw new Error('Invalid asset path'); }
  if (decoded.includes('\0') || decoded.includes('\\') || decoded.split('/').includes('..')) throw new Error('Invalid asset path');
  const result = path.resolve(base, '.' + (decoded === '/' ? '/index.html' : decoded));
  if (result !== path.resolve(base) && !result.startsWith(path.resolve(base) + path.sep)) throw new Error('Invalid asset path');
  return result;
}
function validTransportConfig(value, expectedAppKey) {
  if (!value || Object.keys(value).sort().join(',') !== 'appKey,token,userId') return false;
  return value.appKey === expectedAppKey && typeof value.userId === 'string' && value.userId.length > 0 && value.userId.length <= 256 && typeof value.token === 'string' && value.token.length > 0 && value.token.length <= 8192;
}
module.exports = { developmentURL, trustedFrame, assetPath, validTransportConfig };
