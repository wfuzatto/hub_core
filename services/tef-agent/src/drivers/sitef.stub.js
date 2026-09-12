'use strict';

// The real CliSiTef integration will live behind the same driver contract as mock.
// It is intentionally not enabled until the vendor libraries, terminal credentials
// and homologation environment are provisioned. Never implement direct PAN/PIN reads here.
function createSitefDriver() {
  throw new Error('SiTef driver not provisioned; use TEF_DRIVER=mock for Docker tests');
}

module.exports = { createSitefDriver };
