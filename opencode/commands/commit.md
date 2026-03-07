---
description: Stage all changes and commit immediately without confirmation
---

Immediately, without asking for confirmation:
1. Run `git add -A`
2. Run `git diff --cached` to inspect what is staged
3. Run `git log --oneline -5` to match existing commit message style
4. Write a concise commit message in conventional commits style (`feat:`, `fix:`, `chore:`, `docs:`, etc.) based on the diff
5. Run `git commit -m "<message>"`

Do not push. Do not ask for confirmation.
