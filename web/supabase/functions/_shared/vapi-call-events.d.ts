// Types for vapi-call-events.js (plain JS so n8n can inline the same code).
export type CallEventPlan = {
  record: Record<string, unknown> | null;
  inbound: Record<string, unknown> | null;
  status: Record<string, unknown> | null;
};
export function eventTime(ts: unknown): string | null;
export function planCallEvent(message: unknown): CallEventPlan;
