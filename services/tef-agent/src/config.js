'use strict';

function num(name, fallback) {
  const value = Number(process.env[name]);
  return Number.isFinite(value) ? value : fallback;
}

module.exports = {
  port: num('PORT', 8766),
  driver: String(process.env.TEF_DRIVER || 'mock').toLowerCase(),
  terminalId: process.env.TEF_TERMINAL_ID || 'TEF-DOCKER-01',
  dataDir: process.env.TEF_DATA_DIR || '/app/data',
  token: process.env.TEF_AGENT_TOKEN || '',
  callbackUrl: process.env.TEF_CALLBACK_URL || '',
  callbackSecret: process.env.TEF_CALLBACK_SECRET || '',
  callbackTimeoutMs: num('TEF_CALLBACK_TIMEOUT_MS', 5000),
  mock: {
    cardDelayMs: num('TEF_MOCK_CARD_DELAY_MS', 800),
    pinDelayMs: num('TEF_MOCK_PIN_DELAY_MS', 800),
    authorizeDelayMs: num('TEF_MOCK_AUTHORIZE_DELAY_MS', 800),
    decision: String(process.env.TEF_MOCK_DECISION || 'approve').toLowerCase()
  }
};
