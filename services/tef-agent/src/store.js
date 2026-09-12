'use strict';

const fs = require('fs');
const path = require('path');

function createStore(dataDir) {
  fs.mkdirSync(dataDir, { recursive: true });
  const file = path.join(dataDir, 'transactions.json');
  let state = { transactions: {}, terminal: { busy_session_id: null } };

  function load() {
    try {
      if (fs.existsSync(file)) {
        const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
        if (parsed && typeof parsed === 'object') state = parsed;
      }
    } catch (error) {
      console.error('[tef-agent] failed to load journal', error);
    }
    state.transactions ||= {};
    state.terminal ||= { busy_session_id: null };
  }

  function save() {
    const tmp = `${file}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(state, null, 2));
    fs.renameSync(tmp, file);
  }

  function get(sessionId) { return state.transactions[sessionId] || null; }
  function all() { return Object.values(state.transactions); }
  function put(tx) { state.transactions[tx.session_id] = tx; save(); return tx; }
  function terminal() { return { ...state.terminal }; }
  function acquire(sessionId) {
    const current = state.terminal.busy_session_id;
    if (current && current !== sessionId) return false;
    state.terminal.busy_session_id = sessionId;
    save();
    return true;
  }
  function release(sessionId) {
    if (state.terminal.busy_session_id === sessionId) {
      state.terminal.busy_session_id = null;
      save();
    }
  }

  load();
  return { get, all, put, terminal, acquire, release, save };
}

module.exports = { createStore };
