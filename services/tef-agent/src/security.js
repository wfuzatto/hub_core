'use strict';

const crypto = require('crypto');

function safeEqual(a, b) {
  const x = Buffer.from(String(a || ''));
  const y = Buffer.from(String(b || ''));
  if (!x.length || x.length !== y.length) return false;
  return crypto.timingSafeEqual(x, y);
}

function requireToken(req, res, token) {
  if (!token) return true;
  const auth = String(req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  const provided = req.headers['x-tef-token'] || auth;
  if (!safeEqual(token, provided)) {
    res.writeHead(401, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: 'UNAUTHORIZED' }));
    return false;
  }
  return true;
}

function hmacHex(secret, body) {
  return crypto.createHmac('sha256', secret).update(body).digest('hex');
}

module.exports = { requireToken, hmacHex };
