'use strict';

const crypto = require('crypto');

function now() { return new Date().toISOString(); }
function sleep(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }

function createMockDriver({ config, store, callback }) {
  const running = new Set();

  async function emit(tx, status, extra = {}) {
    tx.status = status;
    tx.updated_at = now();
    Object.assign(tx, extra);
    store.put(tx);
    await callback.send({
      event_id: crypto.randomUUID(),
      external_id: tx.session_id,
      payment_id: tx.payment_id,
      terminal_id: tx.terminal_id,
      status,
      details: {
        brand: tx.brand || null,
        network: tx.network || null,
        nsu: tx.nsu || null,
        authorization_code: tx.authorization_code || null,
        receipt: tx.receipt || null,
        tef_state: status
      }
    });
  }

  async function run(sessionId) {
    if (running.has(sessionId)) return;
    const tx = store.get(sessionId);
    if (!tx || ['AUTHORIZED','APPROVED','DECLINED','CANCELED','ERROR','REFUNDED'].includes(tx.status)) return;
    running.add(sessionId);
    try {
      await emit(tx, 'WAITING_CARD');
      await sleep(config.mock.cardDelayMs);
      if (store.get(sessionId)?.status === 'CANCELED') return;
      await emit(tx, 'CARD_READ', { brand: 'VISA', network: 'MOCKNET' });
      if (tx.method === 'debit_card' || tx.method === 'credit_card') {
        await sleep(config.mock.pinDelayMs);
        if (store.get(sessionId)?.status === 'CANCELED') return;
        await emit(tx, 'WAITING_PIN');
      }
      await sleep(config.mock.authorizeDelayMs);
      if (store.get(sessionId)?.status === 'CANCELED') return;
      if (config.mock.decision === 'decline') {
        await emit(tx, 'DECLINED', { decline_code: 'MOCK_DECLINED' });
        store.release(sessionId);
        return;
      }
      await emit(tx, 'AUTHORIZED', {
        nsu: String(Date.now()).slice(-10),
        authorization_code: crypto.randomBytes(3).toString('hex').toUpperCase(),
        receipt: `TEF MOCK\nTERMINAL ${tx.terminal_id}\nVALOR ${(tx.amount_cents / 100).toFixed(2)}\nAUTORIZADO`
      });
    } catch (error) {
      tx.error = String(error.message || error);
      await emit(tx, 'ERROR');
      store.release(sessionId);
    } finally {
      running.delete(sessionId);
    }
  }

  async function start(input) {
    const existing = store.all().find(tx => tx.payment_id === input.payment_id);
    if (existing) return existing;
    const sessionId = crypto.randomUUID();
    if (!store.acquire(sessionId)) {
      const err = new Error('Terminal busy');
      err.code = 'TERMINAL_BUSY';
      err.status = 409;
      throw err;
    }
    const tx = {
      session_id: sessionId,
      payment_id: input.payment_id,
      terminal_id: input.terminal_id,
      method: input.method,
      amount_cents: input.amount_cents,
      installments: input.installments || 1,
      status: 'QUEUED',
      created_at: now(),
      updated_at: now()
    };
    store.put(tx);
    setImmediate(() => run(sessionId));
    return tx;
  }

  async function confirm(sessionId) {
    const tx = store.get(sessionId);
    if (!tx) throw Object.assign(new Error('Transaction not found'), { code: 'NOT_FOUND', status: 404 });
    if (tx.status === 'APPROVED') {
      store.release(sessionId);
      return tx;
    }
    if (tx.status !== 'AUTHORIZED') throw Object.assign(new Error(`Cannot confirm in ${tx.status}`), { code: 'INVALID_STATE', status: 409 });
    await emit(tx, 'APPROVED', { confirmed_at: now() });
    store.release(sessionId);
    return tx;
  }

  async function cancel(sessionId) {
    const tx = store.get(sessionId);
    if (!tx) throw Object.assign(new Error('Transaction not found'), { code: 'NOT_FOUND', status: 404 });
    if (tx.status === 'CANCELED') {
      store.release(sessionId);
      return tx;
    }
    if (['APPROVED','REFUNDED'].includes(tx.status)) throw Object.assign(new Error(`Cannot cancel in ${tx.status}`), { code: 'INVALID_STATE', status: 409 });
    await emit(tx, 'CANCELED', { canceled_at: now() });
    store.release(sessionId);
    return tx;
  }

  async function refund(sessionId, amountCents) {
    const tx = store.get(sessionId);
    if (!tx) throw Object.assign(new Error('Transaction not found'), { code: 'NOT_FOUND', status: 404 });
    if (!['APPROVED','REFUNDED'].includes(tx.status)) throw Object.assign(new Error(`Cannot refund in ${tx.status}`), { code: 'INVALID_STATE', status: 409 });
    tx.refund_amount_cents = amountCents;
    await emit(tx, 'REFUNDED', { refunded_at: now() });
    return tx;
  }

  function recover() {
    const terminalState = store.terminal();
    const busySessionId = terminalState.busy_session_id;
    if (busySessionId) {
      const busy = store.get(busySessionId);
      if (!busy || ['APPROVED','DECLINED','CANCELED','ERROR','REFUNDED'].includes(busy.status)) {
        store.release(busySessionId);
      }
    }
    for (const tx of store.all()) {
      if (['QUEUED','WAITING_CARD','CARD_READ','WAITING_PIN','PROCESSING'].includes(tx.status)) {
        if (store.acquire(tx.session_id)) setImmediate(() => run(tx.session_id));
      }
      // AUTHORIZED deliberately remains locked until the orchestrator confirms
      // or cancels it after reconciling the business transaction.
    }
  }

  return { name: 'mock', start, confirm, cancel, refund, recover };
}

module.exports = { createMockDriver };
