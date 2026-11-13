# Zella Voice: payments, billing and scale architecture

> **Status: DRAFT for the owner's review (12 Nov 2026).** Nothing here is built, applied or switched on. It designs how
> the commercial policy in `docs/ARCHITECTURE.md` §17 is implemented. When the owner approves it, the parts that change
> the required design move into `ARCHITECTURE.md` and this file becomes the detailed reference. Real charges, refunds
> and auto-reloads need the owner's explicit approval before they go live (`NN-3`, `NN-9`, `BIL-10`).

Contents: [1 Goals](#1-goals-and-non-negotiables) · [2 Context](#2-system-context) · [3 Components](#3-components-and-trust-boundaries)
· [4 Data model](#4-data-model) · [5 Money rules](#5-money-rules) · [6 Flows](#6-flows) · [7 State machines](#7-state-machines)
· [8 Idempotency](#8-idempotency-and-safe-retries) · [9 Security](#9-security) · [10 Reconciliation](#10-reconciliation-and-audit)
· [11 Scale](#11-scalable-architecture-1-to-10000-people) · [12 Failure modes](#12-failure-modes) · [13 Testing](#13-testing)
· [14 Rollout](#14-rollout-and-gates) · [15 Open points](#15-open-points)

---

## 1. Goals and non-negotiables

| # | Goal | How |
|---|---|---|
| G1 | **No card data ever touches Zella Voice** (`NN-9`) | Cards are entered only on Razorpay's hosted checkout. We store provider IDs, never card numbers, CVV or bank details. PCI scope stays at the smallest level (hosted payment page). |
| G2 | **No money movement is applied twice, and none is lost silently** | Layers that work together (§8): scoped idempotency keys, a de-duplicating webhook inbox, an outbox for every provider call, unique keys on provider object IDs and local operations, and reconciliation; an outcome we cannot confirm is held and alerted, never guessed. |
| G3 | **The database decides; screens only ask** (`NN-6`, `SEC-5`) | Prices, eligibility, proration and limits are computed in database functions. The browser never sends an amount. |
| G4 | **The provider is the source of truth for money; we are the source of truth for entitlement** | A payment is "paid" only when a verified webhook (or a server-side fetch from Razorpay) says so. Minutes, texts and emails are granted only by our ledger. |
| G5 | **Nothing is lost and nothing is guessed** | Unknown outcomes are reconciled with the provider before any retry. Every change is an append-only ledger entry with its source. |
| G6 | **A live call is never cut** (`BIL-5`) | Entitlement checks happen before a call is answered by the AI; a call in progress always finishes. |
| G7 | **Same speed with 1 or 10,000 people** | Stateless functions, pooled connections, per-business balance rows, queues with `SKIP LOCKED`, indexes on every tenant query (§11). |
| G8 | **Every sensitive action is audited and reversible where money allows** | Refunds, credits, plan changes and admin adjustments need a reason, a second confirmation and leave an audit record (`SEC-18`). |

---

## 2. System context

```mermaid
flowchart LR
  subgraph People
    ZO[Zella Voice owner<br/>platform admin]
    BO[Business owner<br/>CRM]
    CA[Caller]
  end
  subgraph ZV[Zella Voice]
    WEB[Web apps<br/>admin + CRM<br/>Cloudflare]
    EDGE[Edge functions<br/>Supabase]
    DB[(Postgres<br/>single source of truth)]
    WK[Workers<br/>billing jobs]
  end
  RZ[Razorpay<br/>hosted checkout · subscriptions ·<br/>refunds · disputes]
  VAPI[Vapi + Telnyx<br/>calls · texts]
  RS[Resend<br/>receipts and notices]

  ZO -->|create business, plan, credits| WEB
  BO -->|pay, buy packs, cancel, refund request| WEB
  WEB -->|signed-in requests| EDGE
  EDGE --> DB
  BO -. card entered only here .-> RZ
  RZ -->|signed webhooks| EDGE
  WK -->|outbox commands| RZ
  WK --> DB
  CA --> VAPI -->|usage events| EDGE
  WK --> RS
```

---

## 3. Components and trust boundaries

```mermaid
flowchart TB
  subgraph Browser[Untrusted: browser]
    UI[CRM Billing & Subscription page<br/>admin Create Business step 11]
    RZJS[Razorpay Checkout<br/>hosted, card entry]
  end
  subgraph Edge[Trusted: edge functions · stateless]
    BAPI[billing-api<br/>session + role checked<br/>idempotency key required]
    BWH[billing-webhook<br/>raw-body HMAC · size limit ·<br/>inbox write only]
    BWK[billing-worker<br/>outbox sender · reconciler]
  end
  subgraph Data[Trusted: Postgres · RLS on every table]
    FN[Billing functions<br/>security definer · role check first ·<br/>pinned search_path]
    T[(plans · business_plans · subscriptions ·<br/>invoices · payments · refunds ·<br/>packs · balances · ledgers ·<br/>inbox · outbox · idempotency_keys)]
  end
  RZ[Razorpay API]

  UI -->|HTTPS + JWT + Idempotency-Key| BAPI
  UI --> RZJS
  RZJS -->|order_id, payment_id, signature| BAPI
  BAPI -->|rpc| FN --> T
  RZ -->|webhook| BWH -->|rpc: inbox insert| FN
  BWK -->|claim SKIP LOCKED| FN
  BWK -->|server key, timeout 10s| RZ
```

| Boundary | Rule |
|---|---|
| Browser → edge | Signed-in session required. The function re-checks the role in the database (owner for billing, `billing.manage` + MFA for admins). The browser sends **what** it wants (plan change, pack ID), never **how much** it costs. |
| Razorpay → edge | HMAC-SHA256 signature over the **raw** body with the webhook secret, compared in constant time; body limit 500 KB; unknown event types acknowledged and ignored; the function only writes to the inbox, so it answers fast. |
| Edge → Razorpay | Only workers call Razorpay, with the key secret from edge secrets, a 10 s timeout and the per-operation idempotency and recovery rules of §8. |
| Edge → database | Server key used only by workers and the webhook. User requests run as the user, so row security applies. |
| Admin actions | Platform-admin functions with a named permission, MFA, a reason and an audit row. |

---

## 4. Data model

Existing tables are kept and extended; nothing is dropped (`DB` rules: expand, then contract).

```mermaid
erDiagram
  businesses ||--o{ business_plans : "has versions"
  businesses ||--|| subscriptions : has
  business_plans ||--o{ subscriptions : "current version"
  subscriptions ||--o{ invoices : bills
  invoices ||--o{ invoice_lines : contains
  invoices ||--o{ payments : "paid by"
  payments ||--o{ refunds : "refunded by"
  payments ||--o{ disputes : "disputed by"
  businesses ||--o{ pack_purchases : buys
  businesses ||--o{ allowance_buckets : "has balances"
  allowance_buckets ||--o{ usage_records : "consumed by"
  businesses ||--o{ service_credits : earns
  businesses ||--o| auto_reload_settings : sets
  billing_events }o--|| businesses : "about"
  billing_outbox }o--|| businesses : "commands for"
  money_ledger }o--|| businesses : "posts for"
```

| Table | New or existing | Purpose | Key rules |
|---|---|---|---|
| `business_plans` | new (built, step 2, not applied) | The business's own plan, **versioned**: tier label (Base or Pro), interval, price, setup fee, allowances, languages, caps, trial on/off; every value entered per business, no presets | append a new version per change, never edit; `effective_from`; integer cents |
| `plans` | existing | stays for compatibility; prices move to integer cents (`BIL-7`) | its "anyone can view active plans" policy must not expose per-business prices |
| `subscriptions` | existing | state machine (§7) | one per business (existing unique key); state changes only through functions |
| `invoices`, `invoice_lines` | new | what was charged and why: plan, setup fee, pack, overage, proration, credit, tax | immutable once `issued`; corrections are credit notes |
| `payments` | existing | provider payments; add unique `(provider, external_payment_id)`; amounts in cents | status moves forward only |
| `refunds` | new | requested → approved → sending → processed, failed or uncertain | unique `(provider, external_refund_id)`; **reserved amount** counted while requested, approved, sending or uncertain; sum of reserved and processed ≤ captured; every refund approved by the Zella Voice owner |
| `disputes` | new | chargebacks; suspend while open (`REQ-BIL-37`) | from webhooks only |
| `pack_purchases` | new (built, step 2, not applied) | each pack bought: kind, quantity, price, purchased_at, expires_at (end of the period it was bought in, REQ-BIL-20), rollover_allowed (20% of a minutes pack, 0 for texts and emails), remaining | refundable only if unused and ≤ 14 days |
| `allowance_buckets` | new (built, step 2, not applied) | **current balances** per business and resource: rollover, plan, each pack | one row per bucket; updated in the same transaction as the ledger entry (§11) |
| `billing_periods` | new (built, step 2, not applied) | one row per business per monthly allowance period (yearly plans too, D-46) | every change to a business's balances locks this row, so concurrent usage is serialised |
| `usage_charges` | new (built, step 2, not applied) | every subtraction from, or return to, a balance: quantity, the buckets used, what no balance covered | idempotency key unique (`call:`, `sms:`, `email:`); never edited; serves as the usage key registry until partitioning |
| `billing_pack_catalog` | new (built, step 2, not applied) | the fixed pack prices of §17.3 | platform-owned |
| `usage_records` | existing | append-only usage ledger | idempotency key unique; adjustments, never edits; if partitioned (§11), uniqueness is kept in `usage_keys` |
| `service_credits` | new | outage credits (`REQ-BIL-46`) | capped at one month's fee; applied to next invoices |
| `auto_reload_settings` | new (built, step 2, not applied) | threshold, pack, monthly spend cap, on/off | owner only; changes audited |
| `billing_events` | existing | **webhook inbox**; unique `(provider, external_event_id)` | applied once, in order, never backwards; **never partitioned** (processed events are archived after a retention period, keeping their keys) |
| `provider_accounts` | new | the Razorpay account and environment (live or test) each event and object must match | platform admin only; no secrets stored here |
| `payment_quarantine` | new | events or payments that failed the binding check (§6.0a) or arrived during a secret-compromise window | nothing is granted until a person resolves it; audited |
| `usage_keys` | new, when partitioning | one row per usage idempotency key, **not partitioned** | inserted in the same transaction as the usage entry, so a duplicate is rejected across all months |
| `billing_outbox` | new | **commands to Razorpay** (create order, charge, refund, cancel) | written in the same transaction as the business change (§8) |
| `idempotency_keys` | new | user request keys: unique `(business_id, operation, key)`, request-body hash, stored response | 24 h retention; same key + different body = 409; authorisation re-checked before a stored response is returned |
| `money_ledger` | new | **double-entry** journal: every cent in or out (charge, payment, refund, credit, tax) | each posting balances to zero; the books can be rebuilt from it; each posting has an operation key |
| `ledger_operation_keys` | new, **not partitioned** | one row per ledger operation key (`invoice:`, `payment:`, `refund:`, `credit:` …) | inserted in the same transaction as the postings, so the same operation can never be posted twice in any month |

**Why a double-entry money ledger:** each invoice, payment, refund and credit posts two or more balancing lines,
for example *receivable +$299 / revenue −$299*, then *cash +$299 / receivable −$299*. Any mismatch shows up as a
non-zero balance, which makes reconciliation with Razorpay exact and auditable.

---

## 5. Money rules

| Rule | Detail |
|---|---|
| Amounts | `bigint` cents plus a currency code (`BIL-7`). Never floats. Display in the business's locale. |
| Currency | Customers are charged in USD (`REQ-BIL-28`); Razorpay amounts are in the smallest unit (cents), so no conversion inside our code. **Razorpay settles to Zella Voice in INR** at the exchange rate when the payment is created: each payment stores the USD amount charged and, from the settlement report, the INR amount, rate and fees, so reconciliation (§10) matches both. |
| Rounding | Proration and per-day credits use integer maths, rounding **half up to the cent once, at the line level**; the invoice total is the sum of rounded lines. |
| Proration (upgrade) | `charge = round((new_price − old_price) × remaining_seconds / period_seconds)`; extra allowance for the rest of the cycle is prorated the same way (`REQ-BIL-30`). |
| Service credit | `round(monthly_fee / 30) × affected_days`, capped at `monthly_fee` (`REQ-BIL-46`). |
| Tax | A separate invoice line whose rule is **not built until D-50 is decided**. The design leaves a tax line and a tax ID on the invoice. |
| Prices come from | `business_plans` (plan, setup fee) and a fixed `pack_catalog` (§17.3 prices). Never from the request. |

---

## 6. Flows

### 6.1 Create Business → first payment

```mermaid
sequenceDiagram
  autonumber
  actor ZO as Zella Voice owner
  participant ADM as Admin app
  participant DB as Postgres
  actor BO as Business owner
  participant API as billing-api
  participant RZ as Razorpay
  participant WH as billing-webhook
  participant WK as billing-worker

  ZO->>ADM: Step 11: label Base or Pro, enter price, setup fee, caps, trial on/off
  ADM->>DB: margin and limit checks (REQ-BIL-55, 56) → warnings acknowledged with a reason
  ZO->>ADM: review screen → confirm (REQ-BIL-57)
  ADM->>DB: admin_business_plan_set (audited) → business_plans v1
  DB-->>ADM: plan saved · invite owner
  BO->>DB: open invite link, create password (billing date if no trial)
  BO->>API: GET checkout summary
  API->>DB: zella_billing_checkout_quote(business) → amounts from business_plans
  BO->>API: POST start checkout (Idempotency-Key K1)
  API->>DB: zella_billing_start_checkout(K1) → invoice draft + outbox "create order/subscription"
  WK->>DB: claim outbox row (SKIP LOCKED)
  WK->>RZ: create order / subscription (order ID stored at once · notes.outbox_id)
  RZ-->>WK: order_id / subscription_id
  WK->>DB: store provider IDs
  API-->>BO: open Razorpay hosted checkout (order_id only)
  BO->>RZ: enter card on Razorpay's page
  RZ-->>BO: payment_id + signature
  BO->>API: confirm (payment_id, order_id, signature)
  API->>API: verify HMAC(order_id|payment_id) — shows "processing"
  RZ->>WH: webhook payment.captured (signed)
  WH->>DB: inbox insert (dedupe on event id) → 200
  DB->>DB: binding check (§6.0a) → payment paid, invoice paid, subscription active, buckets granted, ledger postings
  DB-->>BO: CRM shows "Active"
```

The browser confirmation only shows "processing". **Access is granted only when the verified webhook (or the worker's
fetch from Razorpay) confirms the payment, and the payment passes the binding check below.** A lost browser callback
never loses a payment, and a forged callback never grants anything.

### 6.0a Payment binding (applies to every paid grant)

Before any paid access, allowance, pack or invoice status is granted, one database function checks that the captured
payment belongs to exactly what we expected. **All of these must match a row we created ourselves:**

| Check | Against |
|---|---|
| Provider account and environment (live or test) | the configured Razorpay account; a test-mode event can never grant in live, and the reverse |
| Business | derived from **our own** mapping (the order or subscription we created and stored for that business), never from browser input or provider `notes` alone |
| Order or subscription | an order ID or subscription ID stored by us before checkout |
| Invoice | the open invoice that order was created for |
| Amount and currency | the invoice total in cents, in USD |
| Status | `captured` (a `subscription.activated` event alone is **not** proof that an invoice was paid; for subscriptions the grant needs the captured payment of that invoice, from `subscription.charged` or a server-side fetch) |

Any missing, ambiguous or mismatched field puts the event in **quarantine** (no grant, platform alert, a person
decides). A trial authorisation (§6.2) is a separate, unpaid confirmation and never marks an invoice paid. The grant,
the invoice update and the ledger postings happen in **one transaction**, guarded by unique keys on the provider
payment ID and on the local operation (invoice, pack purchase), so the same money can never be applied twice.

### 6.2 Trial: card at the start, charged at the end (`REQ-BIL-11`, `REQ-BIL-12`)

```mermaid
sequenceDiagram
  autonumber
  actor BO as Business owner
  participant DB as Postgres
  participant WK as billing-worker
  participant RZ as Razorpay
  participant WH as billing-webhook

  BO->>DB: accept trial (5 days · 20 min · 5 texts · 5 emails)
  DB->>DB: trial requested · subscription stays pending_payment · nothing granted yet
  WK->>RZ: create subscription with start date = trial end (notes.outbox_id = outbox row)
  RZ-->>BO: hosted page: authorise card (3-D Secure), no charge now
  RZ->>WH: webhook: subscription authenticated (signed)
  WH->>DB: inbox → subscription = trialing, trial_end_at set, trial buckets granted
  Note over DB: abandoned or failed authorisation → still pending_payment, no trial, no buckets
  Note over DB: trial reminders at day 3 and day 4 (email + in-app)
  alt owner cancels before trial end
    BO->>DB: cancel → outbox "cancel subscription" · nothing charged
  else trial ends, charge succeeds
    RZ->>WH: subscription.charged (first charge)
    WH->>DB: inbox → subscription active, billing date = trial end, plan buckets granted
  else trial ends, charge fails
    RZ->>WH: payment.failed
    WH->>DB: trialing → past_due · trial buckets end · same retries and 5-day pause as §6.3
  end
```

**Trial dates stay aligned.** The subscription is created with Razorpay's start date = creation time + 5 days and a
short authorisation window (the subscription link expires after 24 hours). The local `trial_end_at` is always set to
**Razorpay's stored start date**, never recomputed from the authorisation time, so the trial end and the first charge
are the same moment. If the owner authorises late within the window, the trial is correspondingly shorter (by at most
24 hours) and the trial page shows the exact end date. If the window passes without authorisation, that subscription
expires unused and a new one is created when the owner returns. The exact window behaviour is confirmed in Razorpay
test mode before the trial ships (D-51).

Trial abuse guard (D-48, proposed): one trial per business, per phone number and per owner email domain. **No
card-derived identifier is used** (not even a fingerprint), because card details are never collected (`NN-9`). A repeat
is offered a paid plan instead.

### 6.3 Renewal and failed payment (`REQ-BIL-33`)

```mermaid
sequenceDiagram
  autonumber
  participant RZ as Razorpay
  participant WH as billing-webhook
  participant DB as Postgres
  participant WK as billing-worker
  actor BO as Business owner

  RZ->>WH: subscription.charged (success)
  WH->>DB: invoice paid · new period · reset monthly buckets · rollover bucket: up to 20% of plan minutes + up to 20% of each minutes pack (expires next period)
  RZ->>WH: payment.failed
  WH->>DB: subscription past_due (past_due_since set)
  loop days 2, 3, 4
    WK->>RZ: retry charge (one attempt row per try · stored order checked first)
    WK->>BO: email + in-app notice
  end
  alt paid
    RZ->>WH: payment.captured → active · new period · reset monthly buckets · rollover bucket (same rules as subscription.charged, applied once per invoice)
  else 5 days overdue
    DB->>DB: AI receptionist paused · calls to fallback number · data kept 30 days
  end
```

### 6.4 Packs and auto-reload, race-free (`REQ-BIL-23`)

```mermaid
sequenceDiagram
  autonumber
  participant CALL as Call finalised
  participant DB as Postgres
  participant WK as billing-worker
  participant RZ as Razorpay

  CALL->>DB: usage entry (idempotent) → consume buckets in order: rollover → plan → packs (oldest first)
  DB->>DB: balance ≤ owner's threshold AND auto-reload on?
  DB->>DB: lock auto_reload_settings row (FOR UPDATE) · reload already pending? spend this month + pack ≤ cap?
  DB->>DB: create pack_purchase (pending) + outbox "charge saved card" — one per threshold crossing
  WK->>RZ: charge saved payment method (one attempt row · stored order checked first)
  RZ-->>DB: webhook payment.captured → pack bucket granted, receipt emailed
  Note over DB: if the cap would be exceeded: no charge, owner alerted · at 100% calls go to the fallback number
```

A unique partial index `(business_id) where status = 'pending'` on auto-reload purchases makes a second reload
impossible while one is in flight, however many calls finish at the same moment.

### 6.5 Entitlement check at call time (`REQ-BIL-22`)

```mermaid
flowchart LR
  in[Inbound call] --> a{assistant assembly:<br/>minutes left > 0?<br/>a pending reload does not count}
  a -- yes --> ai[AI answers<br/>call never cut]
  a -- no --> fb[Forward to the business's<br/>fallback number]
  ai --> end1[Call finalised → usage entry]
  end1 --> th{crossed 80% / 100%?}
  th -- yes --> al[Alert once per period<br/>unique threshold event]
```

The check reads **one balance row** per business (indexed, no summing), so it costs the same at any scale.

### 6.6 Upgrade and downgrade (`REQ-BIL-30`)

```mermaid
flowchart TB
  up[Upgrade requested] --> q[Quote: prorated difference<br/>computed in the database]
  q --> c[Owner confirms] --> o[Invoice + outbox charge]
  o --> p{payment confirmed by webhook?}
  p -- yes --> g[New business_plans version now ·<br/>prorated extra allowance this cycle]
  p -- no --> keep[Stay on current plan]
  dn[Downgrade requested] --> s[Scheduled for next billing date<br/>features above the lower plan end then]
```

### 6.7 Refund request with server-side eligibility (`REQ-BIL-38`…`45`)

```mermaid
sequenceDiagram
  autonumber
  actor BO as Business owner
  participant API as billing-api
  participant DB as Postgres
  actor ZO as Zella Voice owner
  participant WK as billing-worker
  participant RZ as Razorpay

  BO->>API: GET refund eligibility
  API->>DB: zella_refund_eligibility(business) → {eligible, amount, reason_code}
  API-->>BO: button active, or greyed with the reason
  BO->>API: POST refund request (Idempotency-Key, second confirmation)
  API->>DB: re-check eligibility in the transaction · reserve the amount → refund "requested"
  ZO->>DB: approve (billing.manage + MFA + reason) → outbox "refund"
  WK->>RZ: create refund (X-Refund-Idempotency = refund id)
  RZ->>DB: webhook refund.processed → refund done, ledger postings, receipt
```

Eligibility is computed again at approval and at sending: a stale screen can never cause a refund that the policy no
longer allows. **Refundable amounts are reserved** when a refund is requested: requested, approved, sending and
uncertain refunds all count against the payment, so concurrent requests can never refund more than was captured.

### 6.8 Disputes (chargebacks)

`payment.dispute.created` → dispute row, account suspended while open (`REQ-BIL-37`), owner alerted.
`dispute.won` → that dispute is closed; the account is restored **only when no other dispute on the subscription is still open** (§7). `dispute.lost` → ledger postings for the loss; the account stays suspended until settled.

---

## 7. State machines

```mermaid
stateDiagram-v2
  [*] --> pending_payment: plan set, owner invited
  pending_payment --> trialing: trial accepted (card authorised)
  pending_payment --> active: first payment confirmed
  trialing --> active: trial-end charge confirmed
  trialing --> cancelled: cancelled during trial
  trialing --> past_due: trial-end charge failed
  active --> past_due: renewal failed
  past_due --> active: paid
  past_due --> paused_nonpayment: 5 days overdue
  paused_nonpayment --> active: balance paid
  paused_nonpayment --> cancelled: 30 days unpaid
  active --> cancel_scheduled: owner cancels
  cancel_scheduled --> active: "continue my plan"
  cancel_scheduled --> cancelled: period ends
  active --> suspended_dispute: chargeback opened
  past_due --> suspended_dispute: chargeback opened
  paused_nonpayment --> suspended_dispute: chargeback opened
  cancel_scheduled --> suspended_dispute: chargeback opened
  trialing --> suspended_dispute: chargeback opened
  suspended_dispute --> restored: last open dispute won or settled
  restored --> [*]: back to the saved previous state
  suspended_dispute --> cancelled: dispute lost and unpaid 30 days
  cancelled --> [*]: data exportable 30 days, then deleted
```

Transitions are allowed only by a table of `(from, to, cause)` checked in one database function. An event that would
move a subscription backwards (an older event arriving late) is recorded and ignored.

**Disputes from any state.** A chargeback can arrive in any state except `cancelled`. The subscription moves to
`suspended_dispute`, and the state it came from is saved **on the subscription** (not on each dispute) when the first
dispute opens.
- **Several disputes:** open disputes are tracked in `disputes`; the subscription stays suspended until **every** one
  is won, settled or lost. A second dispute never overwrites the saved state.
- **Events while suspended:** payment and lifecycle events still apply to the **saved state**, which keeps moving as
  normal; only service stays suspended. For example, a `past_due` subscription whose balance is paid during the dispute
  has its saved state moved to `active`, so it is restored as `active` with no retries or pause; a `cancel_scheduled`
  one whose period ended moves its saved state to `cancelled`.
- **Restore:** when the last dispute closes in the business's favour, the subscription takes the saved state as it is
  then. A lost dispute follows the `dispute lost` path in the diagram.
- A dispute on a `cancelled` subscription is recorded and handled by money only (ledger postings), with no state change.

```mermaid
stateDiagram-v2
  [*] --> draft
  draft --> issued
  issued --> paid
  issued --> payment_failed
  payment_failed --> paid
  issued --> void: never charged
  paid --> partially_refunded
  paid --> refunded
  partially_refunded --> refunded
```

---

## 8. Idempotency and safe retries

Four layers that work **together**; no single layer is relied on alone. Each money operation also has its own
idempotency and recovery rule (table below).

```mermaid
flowchart TB
  subgraph L1[Layer 1 · user requests]
    k[Idempotency-Key header required<br/>idempotency_keys: key + request hash + response]
  end
  subgraph L2[Layer 2 · provider commands]
    ob[billing_outbox row written in the SAME transaction<br/>as the business change · provider IDs stored at once]
  end
  subgraph L3[Layer 3 · provider events]
    ib[billing_events unique provider + event id<br/>out-of-order safe · never backwards]
  end
  subgraph L4[Layer 4 · database constraints]
    uc[unique external_payment_id · external_refund_id ·<br/>one pending auto-reload · one invoice per period ·<br/>usage idempotency_key]
  end
  L1 --> L2 --> L3 --> L4
```

| Situation | What happens |
|---|---|
| Owner double-clicks "Buy pack" | Same `Idempotency-Key` → the stored response is returned; one purchase. Keys are scoped to **(business, operation, key)**, stored with a hash of the request body, and the caller's authorisation is **checked again** before a stored response is returned. |
| Same key, different body | `409 idempotency_key_reused`. |
| Worker crashes after Razorpay accepted the charge but before saving | The outbox row is still `sending`. Our order ID is **stored before the charge call**, so the reconciler fetches that order's payments from Razorpay before any retry and records the real outcome. A receipt is only a label, never relied on as a lookup or a guarantee. Never blind-retry a charge; an outcome that stays uncertain is held and alerted. |
| Worker loses the reply to **create subscription** | Razorpay subscriptions have no receipt lookup. Each create carries `notes.outbox_id`; the reconciler lists the subscriptions created since the attempt (by time window and customer) and matches that note. Found → record it. Not found after the window → a retry is allowed, because an unauthenticated subscription charges nothing; any duplicate found later that was never authenticated is cancelled. **This lookup must be proven in Razorpay test mode before the trial path ships** (D-51); if it cannot be, the trial path waits for another recovery method. |
| Razorpay sends a webhook twice | The event ID is a **delivery de-duplication aid** (it is a header, not part of the signed body), not a replay guarantee. The real protection is semantic: unique keys on the provider payment, refund and dispute IDs and on the local operation, so a repeated event has no second effect. |
| Webhooks arrive out of order | Each event carries the provider's creation time; state only moves forward (§7). An event for an unknown payment is kept and applied when its parent arrives. |
| Our webhook handler times out | Razorpay retries; the inbox makes it safe. The handler only inserts, so it answers in milliseconds. |
| Two calls cross the threshold at once | The auto-reload row lock and the unique pending index allow one reload. |

**Per-operation rules:**

| Operation | Idempotency | Recovery when the reply is lost |
|---|---|---|
| Create order (checkout, pack, upgrade) | one order per local operation; order ID stored at once | an unpaid order charges nothing: mark it unused and create a new one |
| Charge a saved card (renewal retry, auto-reload) | one charge attempt row per invoice attempt, unique | fetch the stored order's payments first; retry only if Razorpay shows none |
| Create subscription | `notes.outbox_id` | §8 table above; proven in test mode before shipping |
| Refund | Razorpay's refund idempotency header (`X-Refund-Idempotency`) set to our refund ID | resend with the same key, or fetch the payment's refunds |
| Cancel subscription | naturally idempotent | fetch the subscription and record its state |

Each flow is enabled only after its provider behaviour is proven in Razorpay test mode (D-51).

**Outbox sending protocol:** claim with `FOR UPDATE SKIP LOCKED` → mark `sending` with a lease → call Razorpay → store the
provider ID at once → mark `sent`. A lease that expires sends the row to **reconcile**, not to retry.

---

## 9. Security

| Area | Control |
|---|---|
| Card data | Razorpay hosted checkout only. No card fields in our pages, logs, analytics or support tools (`NN-9`). |
| Webhook authenticity | HMAC-SHA256 of the raw body with the webhook secret (`X-Razorpay-Signature`), constant-time compare; reject on any mismatch. The event ID only de-duplicates deliveries (it is not part of the signed body); replays have no effect because of unique keys on provider object IDs and local operations (§8). |
| Checkout callback | Verify `HMAC(order_id + "|" + payment_id)` with the key secret, but treat it as a hint only; the webhook or a server-side fetch grants access (§6.1). |
| Amount tampering | The browser never sends an amount. Every amount is computed in the database from `business_plans` and the pack catalog. |
| Authorization | Business billing: **owner role only** (`TEN-9`), checked in the database. Admin billing: `billing.view` / `billing.manage`, MFA, audit. Row security on every billing table; server-only tables have no client policies. |
| Sensitive actions | Refunds, credits, plan overrides, trial extensions: reason, second confirmation, audit (`SEC-18`). **Every provider refund needs the Zella Voice owner's approval** (REQ-BIL-45); there is no automatic or threshold-based refund. |
| Secrets | Razorpay key secret and webhook secret only in edge function secrets; never in tables, code, logs or chat (`NN-2`). Routine rotation: the old and new webhook secrets overlap for a short, planned window. **Suspected compromise is different:** the old secret is revoked at once with no overlap; events received during the exposure window are quarantined and each is re-checked against Razorpay's API (fetch the payment, refund or subscription) before anything is applied. |
| Data minimisation | Store only provider IDs, status and amounts. **No card details of any kind**, not even the last 4 digits or the card brand; the owner manages the card on Razorpay's own page. |
| Rate limits | Checkout start, pack purchase and refund request: per user and per business limits; 429 with retry-after. |
| Fraud | Trial guard (D-48); velocity checks on pack purchases; spend cap on auto-reload; alerts on unusual refund or dispute rates. |
| Logging | Structured logs with business ID and correlation ID; no personal data, no tokens, no full provider payloads. |
| Availability attacks | Webhook body limit 500 KB; JSON bodies limited (`SEC-12`); timeouts on every outbound call (`BE-3`). |

---

## 10. Reconciliation and audit

```mermaid
flowchart LR
  rz[Razorpay: payments, refunds,<br/>disputes, settlements] --> rec[Daily reconciler<br/>worker]
  db[(payments · refunds · invoices ·<br/>money_ledger)] --> rec
  rec --> ok{match?}
  ok -- yes --> done[Mark reconciled]
  ok -- no --> alert[Platform alert + finance task<br/>never auto-corrects money]
```

- **Daily:** every Razorpay payment, refund and dispute of the last 7 days is matched to our rows by provider ID and
  amount. A mismatch raises an alert; a person decides.
- **Ledger check:** the money ledger balances to zero overall and per invoice.
- **Usage check:** allowance balances equal the sum of their ledger entries (rebuilt nightly in a read-only check).
- **Audit:** every admin billing action is in the audit log with who, when, why and before/after values.

---

## 11. Scalable architecture: 1 to 10,000 people

The same design serves one owner or 10,000 people at once because every request is stateless, every tenant query is
indexed by `business_id`, hot counters live in one row per business, and slow work goes through queues.

```mermaid
flowchart TB
  users[1 … 10,000 people<br/>admin + CRM] --> cdn[Cloudflare CDN<br/>static app, cached at the edge]
  users --> edge[Edge functions<br/>stateless · scale out automatically]
  edge --> pool[Connection pooler<br/>transaction mode]
  pool --> pg[(Postgres primary<br/>RLS · indexes · per-business balance rows)]
  pg -. later .-> rr[(Read replica<br/>reports and exports)]
  rz[Razorpay webhooks<br/>bursts] --> edge
  edge -->|insert only| inbox[(inbox / outbox / work items)]
  inbox --> wk[Workers<br/>claim with SKIP LOCKED<br/>scale by adding workers]
  wk --> pg
  calls[Vapi call events] --> edge
```

| Concern | Design | Why it scales |
|---|---|---|
| Web app | Static build on Cloudflare's CDN | Pages are served from the edge; no server per user. |
| API | Edge functions are stateless | More traffic → more instances; no session state to share. |
| Database connections | Pooler in transaction mode | Thousands of requests share a small pool of connections. |
| Tenant queries | Every billing and CRM table indexed on `business_id` (plus time) | Each query touches one business's rows, whatever the total size. |
| Hot path at call time | `allowance_buckets`: one balance row per business and resource, updated with the ledger in one transaction | O(1) reads; locks are per business, so businesses never wait for each other. |
| Webhook bursts | Handler only inserts into the inbox; workers apply | Thousands of events a minute are absorbed; processing catches up safely. |
| Background work | Queues with `FOR UPDATE SKIP LOCKED`, leases and back-off | Add workers to go faster; no double processing. |
| Large tables | `usage_records` and `money_ledger` partitioned by month when they pass ~10 M rows. PostgreSQL enforces uniqueness only within a partition, so each gets a small non-partitioned key registry written in the same transaction: `usage_keys` for usage entries, and `ledger_operation_keys` for money-ledger postings (every posting carries an operation key such as `invoice:<id>`, `payment:<id>`, `refund:<id>` or `credit:<id>`, including postings that have no provider ID, like service credits). The webhook inbox `billing_events` is not partitioned. | Old months stay cold; indexes stay small; duplicates are still rejected across months. |
| Reports and exports | Run against a read replica when load requires | Heavy reads never slow down calls or payments. |
| Realtime screens | Subscriptions filtered by row security, only on the pages that need them | No broadcast of other businesses' data, bounded fan-out. |
| Limits | Per-user and per-business rate limits on write endpoints | One noisy business cannot starve others. |

**Capacity plan (to verify with load tests before launch, §13):**

| Stage | People at once | What is needed |
|---|---|---|
| Pilot | 1–50 | Current setup. |
| Launch | 50–1,000 | Pooler on; indexes checked with `EXPLAIN`; workers outside n8n for billing jobs. |
| Growth | 1,000–10,000 | Larger database compute; read replica for reports; partitioned ledgers; more workers; alerting on queue age and p95 latency. |

**One known bottleneck today:** n8n Cloud Starter allows about 2,500 runs a month (`docs/MEMORY.md`). Billing jobs
(outbox sender, renewals, dunning, reconciliation) must therefore run as database-claimed workers in edge functions,
not as n8n runs. n8n stays for messaging workflows, or moves to a larger plan before scale.

**Targets (SLOs, proposed):** checkout start p95 < 500 ms; webhook acknowledgement p95 < 200 ms; entitlement check
p95 < 20 ms; outbox queue age < 60 s; zero unreconciled payments older than 24 h.

---

## 12. Failure modes

| Failure | Effect | Handling |
|---|---|---|
| Razorpay down | Checkout and charges unavailable | Outbox waits with back-off; owners see "payment provider unavailable, we'll retry"; existing access unaffected. |
| Webhook delayed for hours | Payment shown as "processing" | After 15 min the reconciler fetches the payments of the order ID we stored, applies them through the binding check (§6.0a), and alerts if still unclear. |
| Our database down | Nothing can be granted | Razorpay retries webhooks for up to its retry window; inbox applies them when back. |
| Duplicate charge by the provider | Customer charged twice | Daily reconciliation finds it; full refund within 5–10 business days (`REQ-BIL-43`). |
| Worker crash mid-send | Unknown outcome | Lease expiry → reconcile with the per-operation lookup (stored order or subscription ID, refund idempotency key), never blind retry; held and alerted if still unclear (§8). |
| Clock skew | Wrong period boundaries | All periods computed in the database clock, stored in UTC. |
| Secret leaked | Forged webhooks possible | Incident: revoke the old secret immediately (no overlap), set a new one, quarantine events from the exposure window and apply only those confirmed by fetching the object from Razorpay; rotate the API key too if it may be exposed; review grants made in the window. |

---

## 13. Testing

| Level | What is proven | Where |
|---|---|---|
| Unit | proration, rounding, eligibility rules, signature checks, event mapping | Deno tests, Node tests |
| Database | state machine, uniqueness, ledger balance, row security per role, cross-tenant isolation | isolated test database only |
| Idempotency drills | double click, duplicate webhooks, out-of-order webhooks, crash after send, concurrent threshold crossing, concurrent refund requests that would exceed the captured amount | isolated database + mocked provider |
| Binding and abuse | wrong amount, wrong currency, wrong business mapping, test-mode event in live, `subscription.activated` without a captured payment, forged webhook with a leaked secret: each is quarantined, nothing granted | isolated database + mocked provider |
| Provider sandbox | real Razorpay **test mode**: checkout, trial, renewal, failure, refund, dispute | staging, test keys only |
| Load | 10,000 virtual users on CRM reads; 1,000 webhooks/min burst; 500 concurrent call finalisations | staging, synthetic data |
| Reconciliation | seeded mismatches are detected and alerted, never auto-corrected | isolated database |

No real card, real charge or real customer data is used in any test.

---

## 14. Rollout and gates

```mermaid
flowchart LR
  a[1 · Data model + functions<br/>isolated DB] --> b[2 · Admin step 11 +<br/>CRM billing page, display only]
  b --> c[3 · Razorpay test mode<br/>staging]
  c --> d[4 · Owner approval:<br/>live keys, one pilot business]
  d --> e[5 · Watch reconciliation<br/>for 2 billing cycles]
  e --> f[6 · Open to all businesses]
```

Each step: its own pull request reviewed by CodeRabbit, tests green, the owner's approval for anything that touches
production or real money (`NN-3`, `NN-4`).

---

## 15. Open points

| # | Point | Needed for |
|---|---|---|
| D-51 | Razorpay: recurring USD on international cards is supported per Razorpay's docs (first payment authenticated with 3-D Secure; settled in INR). Still to confirm: international payments activated on the account; a trial with a future start date in test mode; charging the saved card for auto-reload packs | step 3 |
| D-50 | Tax rules (GST on exported services; US state sales tax) | invoices with tax |
| D-44…D-48 | overage, fair-use multiple, annual allowances, founding customers, trial limits | step 1 |
| — | Exact Razorpay event names and payloads, confirmed against Razorpay's current documentation at build time | step 3 |
