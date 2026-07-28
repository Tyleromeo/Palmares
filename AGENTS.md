# Codex repository instructions

Read `CONTRIBUTING.md` completely before editing.

- Use the shared `shared-development` branch unless the user explicitly
  requests another branch.
- Pull with rebase before starting a change.
- Never overwrite or discard work from the other computer or assistant.
- Commit and push each coherent completed chunk promptly.
- Pushing to `shared-development` SHIPS TO THE USER'S PHONE. A GitHub
  Action merges that branch into `main`, which Vercel deploys as the live
  site the iOS app loads. Treat every push as going straight to production:
  verify the change first, and never push work you would not ship.
- When the user asks for a fix to reach their phone, pushing
  `shared-development` is enough - no pull request needed. Confirm it
  landed by checking the deployed page, not just the branch.
- Do not push directly to `main`; the Action owns that merge.

