// Zella - Receptionist Brain: one response with every tool call's answer (Vapi matches them by toolCallId, any order).
return [{ json: { results: $input.all().map((i) => i.json).filter((x) => x && typeof x.toolCallId === 'string') } }];
