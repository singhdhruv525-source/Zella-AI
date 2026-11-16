# Owner onboarding: what the screens still need from the contract

For the backend job (`docs/OWNER_ONBOARDING_CONTRACT.md`, version 1). The screens are wired to version 1 exactly; these
are small gaps, none blocking. Until they are answered, the screens do what is written in each row.

| # | Need | Why | What the screens do meanwhile |
|---|---|---|---|
| 1 | Say how `hours[].weekday` is numbered (0 = Sunday to 6 = Saturday, or ISO 1 = Monday to 7 = Sunday) | Check your details shows the day names | Reads 0 and 7 as Sunday, 1 as Monday, 6 as Saturday |
| 2 | Say whether `services[].duration` and `services[].price` are always display text (as in the example) or can be numbers | Shown as written | Shows them as written |
| 3 | When Stripe Checkout is built: the payment states between `waiting` and `confirmed` (for example pending or failed) and how the screens open Checkout (`checkout_available` plus a call that returns its address) | Screen 6 | Shows "Payment opens here soon", "Payment opens after verification" or "Payment received" only |
| 4 | When an identity provider is chosen: what `rules.identity_provider` names and what the screens need to start its check (for example an inquiry id from a new call) | Screen 4 has one reserved place for the widget | Manual upload only; the reserved place shows nothing while the rule is `none` |
