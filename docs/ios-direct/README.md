# iOS direct wireless POC — G0

Checkpoint: 2026-10-16. Documentation only; G0 evidence prepared for Claude's review. No prototype, signed sender, radio run, or integrated feature is claimed.

## Scope and evidence labels

**Verified (local evidence):** repository/SDK declarations and commands inspected on this date. This label does not mean runtime support. **Documented (source URL):** Apple describes behavior; physical-device/signing validation remains separate. **Hypothesis:** proposed design, experiment, or unproven runtime behavior. These labels apply to the sections/tables explicitly carrying them, including their individual claims.

**Verified (task inputs):** the full project brief was read at `/Users/thomas/Documents/Codex/2026-10-16/referenced-chatgpt-conversation-this-is-an/outputs/iosdirectPOC.md`. The user ratified its §9 targets as written. Hardware/account facts supplied by the user are identified as supplied, rather than independently measured.

The requested product is an iOS 27+ screen-only, full-display background sender and a standalone Mac receiver for two concurrent phones. Runtime must need no AP, internet, hotspot, USB, cloud rendezvous, or shared Apple Account. Authenticated pairing and encrypted screen/control data are required. Audio, remote control, older iOS, Android/Windows changes, distribution, and production integration are outside G0.

## Isolation — Verified (local evidence)

| Item | Observed value |
| --- | --- |
| Worktree | `/Users/thomas/Documents/Claude Code/Mirror-wall POC` |
| Branch | `feat/ios-direct-poc` |
| HEAD / recorded base / local `origin/main` | `70e2f1a1d48ca65ea26fc2a0592760eb543795b3` |
| Origin fetch/push | `https://github.com/justfortonks/mirror-wall` |
| Local remote default | `refs/remotes/origin/main` |
| Initial `git status --porcelain` | Empty |
| Other worktree (inventory only) | `/Users/thomas/Documents/Claude Code/casting app/mirror-wall`, `claude/obs-syphon`, abbreviated HEAD `2240ef2` |

No fetch or remote PR/CI query was made; `origin/main` is the recorded local ref, not a fresh server comparison. The other worktree's files were not inspected or modified. No applicable `AGENTS.md`/`CLAUDE.md` was found in this worktree or `AGENTS.md` in the checked ancestor directories. `.github/CODEOWNERS:1` assigns `@justfortonks`.

Only the six files here are authored. No prototypes directory, Swift/Xcode files, commits, pushes, branch changes, stash, reset, or clean. The explicitly requested SwiftPM baseline attempted normal generated build/cache activity; it stopped at the sandbox boundary. No cache override or sandbox workaround was attempted.

## Documents

- [Feasibility](feasibility.md): exact SDK declarations, toolchain/device probe, signing limits.
- [Architecture](architecture.md): current source ownership and eventual adapter seam.
- [Test plan](test-plan.md): bounded G1 capture and G2 synthetic radio experiments.
- [Results](results.md): run 0 baseline; no hardware results.
- [Handoff](handoff.md): remaining decisions and next bounded assignment.

## Status terms — Verified (brief §11)

- **Documented:** an authoritative source describes support.
- **Built:** the declared target compiled/signed successfully.
- **Synthetic pass:** controlled mock/payload tests passed.
- **Hardware pass:** the declared real-device test passed under recorded conditions.
- **Accepted:** the mandatory acceptance criteria were reviewed against evidence.
- **Blocked / not run:** the prerequisite or evidence is unavailable; identify it.

G0 build/test execution is **Blocked** by sandbox manifest evaluation. G1–G7 are **not run**. No gate is marked Accepted by this audit.

## Rollback — Hypothesis / future human operation

Preserve any wanted uncommitted documentation first. From a shell outside this worktree, use `git -C '<surviving repository worktree>' worktree remove '/Users/thomas/Documents/Claude Code/Mirror-wall POC'`, then `git -C '<surviving repository worktree>' branch -d feat/ios-direct-poc`. Normal removal will refuse a dirty worktree; resolve preservation deliberately, without `--force` or `clean`. If future unmerged commits prevent `branch -d`, archive/review them before deliberately deleting the branch. None of these rollback commands was executed. Do not remove the user's other checkout or the common Git repository.
