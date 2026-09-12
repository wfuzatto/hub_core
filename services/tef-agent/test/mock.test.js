'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { createStore } = require('../src/store');
const { createMockDriver } = require('../src/drivers/mock');

function sleep(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }

test('mock driver authorizes then confirms without duplicating payment', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tef-agent-'));
  const store = createStore(dir);
  const events = [];
  const config = { mock: { cardDelayMs: 5, pinDelayMs: 5, authorizeDelayMs: 5, decision: 'approve' } };
  const callback = { send: async event => events.push(event) };
  const driver = createMockDriver({ config, store, callback });

  const first = await driver.start({ payment_id: 'pay-1', terminal_id: 'TEF-01', method: 'credit_card', amount_cents: 1234, installments: 1 });
  const replay = await driver.start({ payment_id: 'pay-1', terminal_id: 'TEF-01', method: 'credit_card', amount_cents: 1234, installments: 1 });
  assert.equal(first.session_id, replay.session_id);

  for (let i = 0; i < 30 && store.get(first.session_id).status !== 'AUTHORIZED'; i += 1) await sleep(5);
  assert.equal(store.get(first.session_id).status, 'AUTHORIZED');
  assert.equal(store.terminal().busy_session_id, first.session_id);

  await driver.confirm(first.session_id);
  assert.equal(store.get(first.session_id).status, 'APPROVED');
  assert.equal(store.terminal().busy_session_id, null);
  assert.ok(events.some(event => event.status === 'WAITING_CARD'));
  assert.ok(events.some(event => event.status === 'AUTHORIZED'));
  assert.ok(events.some(event => event.status === 'APPROVED'));
});
