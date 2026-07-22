# One-time: move the desktop clone out of Dropbox

**For the desktop session, 2026-07-23 or whenever you next sit down at it.**
Delete this file once the move is done — it's a throwaway note.

## Why

The desktop's working clone currently lives inside Dropbox, at
`~/Library/CloudStorage/Dropbox/palmares copy`. That folder is *also* a git
repo, so two sync engines — Dropbox (continuous, blind) and git (deliberate) —
are both writing the same `.git`. Dropbox can overwrite a file mid-edit,
resurrect a deleted one, or sync a half-written `.git` and corrupt the repo.
"It worked last time" was luck. The laptop already keeps its clone in plain
`~/Documents/palmares`; this brings the desktop in line so git is the only
channel between the two machines.

## Steps (run these on the desktop)

**1. Make sure the Dropbox copy has nothing unpushed.**

```sh
cd ~/Library/CloudStorage/Dropbox/palmares\ copy
git fetch
git status                    # working tree must be clean
git rev-list --left-right --count origin/main...HEAD   # want: 0 0
```

If `status` shows changes, commit and push them first. If the count isn't
`0 0`, reconcile before going further — do **not** move a repo mid-divergence.

**2. Fresh-clone into Documents (don't copy the Dropbox folder — clone clean, so no `.DS_Store` / Dropbox conflict files come along).**

```sh
git clone https://github.com/Tyleromeo/Palmares.git ~/Documents/palmares
cd ~/Documents/palmares
git rev-parse --short HEAD    # should match origin/main
```

The HTTPS remote + your existing `gh` auth work as-is; nothing to reconfigure.

**3. Verify the new clone is complete before deleting anything.**

```sh
git -C ~/Documents/palmares status          # clean
diff <(git -C ~/Documents/palmares rev-parse HEAD) \
     <(git -C ~/Library/CloudStorage/Dropbox/palmares\ copy rev-parse HEAD) \
  && echo "same commit — safe to remove the Dropbox copy"
```

**4. Remove the Dropbox copy.** Deleting it here also removes it from the
laptop's Dropbox mirror — that's intended; the redundant clone should be gone
everywhere.

```sh
rm -rf ~/Library/CloudStorage/Dropbox/palmares\ copy
```

**5. From now on, the desktop works in `~/Documents/palmares`.** Start each
session with `git fetch && git rev-list --left-right --count origin/main...HEAD`
(see CONTRIBUTING). Delete this file and commit the deletion.

## After this, the sync is simply:

- Finish a chunk on either machine → `git push`.
- Sit down at the other machine → `git fetch`, confirm `0 0`, then edit.

No Dropbox in the loop, nothing to think about.
