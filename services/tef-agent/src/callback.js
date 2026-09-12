'use strict';

const { hmacHex } = require('./security');

function createCallback(config) {
  async function send(event) {
    if (!config.callbackUrl) return;
    const body = JSON.stringify(event);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), config.callbackTimeoutMs);
    try {
      const headers = { 'content-type': 'application/json' };
      if (config.callbackSecret) headers['x-webhook-signature'] = `sha256=${hmacHex(config.callbackSecret, body)}`;
      const response = await fetch(config.callbackUrl, { method: 'POST', headers, body, signal: controller.signal });
      if (!response.ok) throw new Error(`callback HTTP ${response.status}`);
    } catch (error) {
      console.warn('[tef-agent] callback failed', error.message);
    } finally {
      clearTimeout(timer);
    }
  }
  return { send };
}

module.exports = { createCallback };
