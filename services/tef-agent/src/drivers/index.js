'use strict';

const { createMockDriver } = require('./mock');

function createDriver({ config, store, callback }) {
  if (config.driver === 'mock') return createMockDriver({ config, store, callback });
  throw new Error(`Unsupported TEF driver in this build: ${config.driver}`);
}

module.exports = { createDriver };
