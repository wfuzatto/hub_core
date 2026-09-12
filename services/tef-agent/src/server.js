'use strict';

const http = require('http');
const config = require('./config');
const { createStore } = require('./store');
const { createCallback } = require('./callback');
const { requireToken } = require('./security');
const { createMockDriver } = require('./drivers/mock');

const store = createStore(config.dataDir);
const callback = createCallback(config);
if (config.driver !== 'mock') throw new Error(`Unsupported TEF driver in this build: ${config.driver}`);
const driver = createMockDriver({ config, store, callback });

function json(res, status, data) {
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  res.end(JSON.stringify(data));
}

async function body(req) {
  let raw = '';
  for await (const chunk of req) {
    raw += chunk;
    if (raw.length > 1024 * 1024) throw Object.assign(new Error('Body too large'), { status: 413, code: 'BODY_TOO_LARGE' });
  }
  return raw ? JSON.parse(raw) : {};
}

function validateNoCardData(value, path = '$') {
  const forbidden = /^(pan|card_?number|cvv2?|cvc2?|track1|track2|pin|password|raw_?card)$/i;
  if (!value || typeof value !== 'object') return;
  for (const [key, child] of Object.entries(value)) {
    if (forbidden.test(key)) throw Object.assign(new Error(`Raw card/PIN data forbidden at ${path}.${key}`), { status: 422, code: 'RAW_CARD_DATA_FORBIDDEN' });
    validateNoCardData(child, `${path}.${key}`);
  }
}

async function handle(req, res) {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  if (req.method === 'GET' && url.pathname === '/health') {
    return json(res, 200, { status: 'ok', service: 'tef-agent', driver: driver.name, terminal_id: config.terminalId, terminal: store.terminal() });
  }
  if (!requireToken(req, res, config.token)) return;

  if (req.method === 'GET' && url.pathname === '/v1/device') {
    return json(res, 200, { terminal_id: config.terminalId, driver: driver.name, transport: config.driver === 'mock' ? 'virtual' : 'unknown', online: true });
  }
  if (req.method === 'GET' && url.pathname === '/v1/status') {
    const terminal = store.terminal();
    return json(res, 200, { terminal_id: config.terminalId, state: terminal.busy_session_id ? 'BUSY' : 'READY', busy_session_id: terminal.busy_session_id });
  }
  if (req.method === 'POST' && url.pathname === '/v1/transactions') {
    const input = await body(req);
    validateNoCardData(input);
    const amount = Number(input.amount_cents);
    const method = String(input.method || '').toLowerCase();
    const terminalId = String(input.terminal_id || config.terminalId);
    if (!input.payment_id) return json(res, 422, { error: 'PAYMENT_ID_REQUIRED' });
    if (!Number.isSafeInteger(amount) || amount <= 0) return json(res, 422, { error: 'INVALID_AMOUNT' });
    if (!['debit_card','credit_card'].includes(method)) return json(res, 422, { error: 'INVALID_METHOD' });
    if (terminalId !== config.terminalId) return json(res, 404, { error: 'TERMINAL_NOT_FOUND', terminal_id: terminalId });
    const tx = await driver.start({ ...input, method, amount_cents: amount, terminal_id: terminalId });
    return json(res, 202, tx);
  }

  const match = url.pathname.match(/^\/v1\/transactions\/([^/]+)(?:\/(confirm|cancel|refund))?$/);
  if (match) {
    const sessionId = decodeURIComponent(match[1]);
    const action = match[2];
    if (req.method === 'GET' && !action) {
      const tx = store.get(sessionId);
      return tx ? json(res, 200, tx) : json(res, 404, { error: 'NOT_FOUND' });
    }
    if (req.method === 'POST' && action === 'confirm') return json(res, 200, await driver.confirm(sessionId));
    if (req.method === 'POST' && action === 'cancel') return json(res, 200, await driver.cancel(sessionId));
    if (req.method === 'POST' && action === 'refund') {
      const input = await body(req);
      const amount = Number(input.amount_cents);
      if (!Number.isSafeInteger(amount) || amount <= 0) return json(res, 422, { error: 'INVALID_AMOUNT' });
      return json(res, 200, await driver.refund(sessionId, amount));
    }
  }

  return json(res, 404, { error: 'NOT_FOUND', path: url.pathname });
}

const server = http.createServer((req, res) => {
  handle(req, res).catch(error => {
    console.error('[tef-agent]', error);
    json(res, Number(error.status || 500), { error: error.code || 'INTERNAL_ERROR', message: Number(error.status || 500) >= 500 ? 'TEF agent internal error' : error.message });
  });
});

server.listen(config.port, '0.0.0.0', () => {
  console.log(`[tef-agent] listening on :${config.port} driver=${driver.name} terminal=${config.terminalId}`);
  driver.recover();
});

process.on('SIGTERM', () => server.close(() => process.exit(0)));
process.on('SIGINT', () => server.close(() => process.exit(0)));
