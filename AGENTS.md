# Instructions for AI agents

This repository is **Zella Voice**. Before reading, changing, testing or deploying anything, read and follow
**[`ZELLA_VOICE_RULES.md`](ZELLA_VOICE_RULES.md)**. Every rule in it is binding for every agent and tool.
How the system works: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

The twelve non-negotiables:

1. No business ever sees or changes another business's data.
2. No secret is ever written where a person or AI could read it later.
3. Nothing reaches the real world (calls, texts, emails, live switches, live voice assistants) without the owner's approval.
4. Production is changed only with the owner's explicit approval, one change at a time, with a backup before and proof after.
5. Nobody pushes to `main`.
6. The database is the single source of truth and the single enforcer of rules.
7. The AI receptionist never invents a fact.
8. Opt-out always wins.
9. No card number ever touches our systems.
10. Every change can be undone.
11. Never claim what didn't happen.
12. The brand is "Zella Voice", never "Zella AI".
