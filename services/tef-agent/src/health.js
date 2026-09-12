'use strict';
module.exports = function health(driver, terminalId, terminal) { return { status: 'ok', service: 'tef-agent', driver, terminal_id: terminalId, terminal }; };
