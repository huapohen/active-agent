'use strict';

class CompanionError extends Error {
  constructor(status, code, message) { super(message); this.status = status; this.code = code; }
}
const problem = (status, code, message) => new CompanionError(status, code, message);
const loopback = host => ['localhost', '127.0.0.1', '[::1]'].includes(host);

function createPolicy(origins) {
  const allowed = origins === undefined ? null : new Set(origins.map(raw => {
    const url = new URL(raw);
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.pathname !== '/' || url.search || url.hash)
      throw problem(422, 'invalid_origins', 'Allowed origins must be HTTP(S) origins without paths, credentials or queries');
    return url.origin;
  }));
  function authorize(raw) {
    if (typeof raw !== 'string' || raw.length > 8192) throw problem(422, 'invalid_url', 'An HTTP(S) URL of at most 8192 characters is required');
    let url;
    try { url = new URL(raw); } catch { throw problem(422, 'invalid_url', 'An absolute HTTP(S) URL is required'); }
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password)
      throw problem(422, 'scheme_denied', 'Only HTTP(S) URLs without embedded credentials are allowed');
    if (allowed ? !allowed.has(url.origin) : !loopback(url.hostname))
      throw problem(403, 'origin_denied', 'The URL origin is outside this companion instance policy');
    return url;
  }
  return {authorize, description: allowed ? {mode: 'explicit_origins', origins: [...allowed]} : {mode: 'loopback_only', hosts: ['localhost', '127.0.0.1', '[::1]']}};
}

function object(value, keys) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some(key => !keys.includes(key)))
    throw problem(422, 'invalid_request', 'Unsupported request fields');
}
function actions(input, policy) {
  object(input, ['actions']);
  if (!Array.isArray(input.actions) || !input.actions.length || input.actions.length > 20)
    throw problem(422, 'invalid_actions', 'A job must contain 1 to 20 fixed actions');
  return input.actions.map(action => {
    const fields = {navigate: ['type', 'url'], click: ['type', 'selector'], type: ['type', 'selector', 'text'], inspect: ['type', 'selector'], screenshot: ['type']};
    if (!action || !Object.hasOwn(fields, action.type)) throw problem(422, 'action_denied', 'Only navigate, click, type, inspect and screenshot are supported');
    object(action, fields[action.type]);
    if (action.type === 'navigate') policy.authorize(action.url);
    if (['click', 'type', 'inspect'].includes(action.type) && !(action.type === 'inspect' && action.selector === undefined)) {
      if (typeof action.selector !== 'string' || !action.selector.trim() || action.selector.length > 500 || /[\x00-\x1f]|>>/.test(action.selector))
        throw problem(422, 'invalid_selector', 'A single CSS selector of at most 500 characters is required');
    }
    if (action.type === 'type' && (typeof action.text !== 'string' || action.text.length > 16000))
      throw problem(422, 'invalid_text', 'Typed text must contain at most 16000 characters');
    return {...action};
  });
}
module.exports = {CompanionError, problem, createPolicy, object, actions};
