import { assertEquals, assertMatch, assertNotMatch } from "jsr:@std/assert@1";
import { mask, maskText } from "./mask.ts";

// Made by the database's own rule on the isolated test server (zprod3 copy), so the two can't drift:
//   select json_agg(json_build_array(v, public.zella_admin_mask(v))) from unnest(array[...]) v
const FROM_ZELLA_ADMIN_MASK: [string, string | null][] = [["", null], ["+15550100123", "…0123"], ["+1 (555) 010-0123", "…0123"], ["555", "…555"], ["abc", "…"], ["unknown", "…"], ["ada@example.com", "a…@example.com"], ["@example.com", "…@example.com"], ["a@b@c", "a…@b"], ["x@", "x…@"], ["12", "…12"], ["Anonymous", "…"], ["+44 20 7946 0958", "…0958"]];

Deno.test("mask matches zella_admin_mask for every fixture", () => {
  for (const [input, expected] of FROM_ZELLA_ADMIN_MASK) assertEquals(mask(input), expected, JSON.stringify(input));
  assertEquals(mask(null), null);
  assertEquals(mask(undefined), null);
});

Deno.test("maskText hides emails and phone numbers inside free text, keeps the rest", () => {
  assertEquals(maskText("Mailbox ada@example.com is full"), "Mailbox a…@example.com is full");
  assertEquals(maskText("Number +1 (555) 010-0123 rejected the call"), "Number …0123 rejected the call");
  assertEquals(maskText("Timeout after 30 seconds, code 503"), "Timeout after 30 seconds, code 503");
  assertEquals(maskText(""), null);
  const out = maskText("to +15550100123 and bob@test.example, then 5550100124") ?? "";
  assertNotMatch(out, /\d{5,}/);
  assertMatch(out, /b…@test\.example/);
});
