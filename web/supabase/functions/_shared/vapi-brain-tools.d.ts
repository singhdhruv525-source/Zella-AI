// Types for vapi-brain-tools.js (plain JS so n8n can inline the same code).
export type Json = Record<string, unknown>;
export type CallContext = { callId: string | null; calledNumber: string | null; vapiNumberId: string | null; callerNumber: string | null; fallbackBusinessId: string | null };
export type BrainPlan = { toolCallId: string; name: string; known: boolean; invalid: string | null; record: Json & { p_tool: string; p_business_id: string | null; p_idempotency_key: string | null } };
export const BRAIN_TOOLS: string[];
export const BOOKING_TOOLS: string[];
export const BRAIN_FAILED: string;
export const BRAIN_UNKNOWN: string;
export function vapiCallContext(message: unknown): CallContext;
export function toolName(tc: unknown): string;
export function toolArgs(tc: unknown): Json;
export function planBrainTool(tc: Json, ctx: CallContext, allowed?: string[]): BrainPlan;
export function toolCallList(message: unknown): Json[];
export function brainToolReply(name: string, toolCallId: string, ok: boolean, body: unknown): Json;
export function brainInvalidReply(name: string, toolCallId: string, why: string): Json;
