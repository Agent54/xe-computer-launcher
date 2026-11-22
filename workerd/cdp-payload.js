// Payloads pass here in both directions, before commands are sent and before
// replies/events are exposed. IWA/controlled-frame rewriting belongs here.
// This is deliberately a no-op; it does not enforce permissions or audit access.
export function rewriteCDPPayload(payload, context) {
  return payload;
}
