# Drivers

`mock` implements the production-shaped contract without touching card hardware. Future `sitef`/`gertef` drivers must expose the same lifecycle (`start`, `confirm`, `cancel`, `refund`, `recover`) and must never return PAN, CVV, track data or PIN to the application.
