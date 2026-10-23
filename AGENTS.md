# Working on claude-pixel-pet

Rules for any agent (Claude Code session or otherwise) that changes this repo.

## Workflow
1. Every change goes through a pull request: work on a branch, push it, and open a PR against `main`. No direct pushes to `main`. The PR description is the record of what changed and why.
2. Build and run it: `./build.sh` builds, installs to `~/Applications/ClaudePet.app`, and relaunches. Check the actual behaviour in the running app, not just that it compiles.
3. Update `README.md` if user-visible behaviour or setup changed.
4. Commit with a short imperative subject that says what changed for the user.
5. **Before merging, run `/simplify` on the PR's whole diff and apply what it finds.** If that changes code, build and check the running app again. Docs-only PRs skip this step. Merging without it has happened before. Don't.
6. Squash-merge, so `main` gets one commit per PR.

## Code
- One file, `main.swift`, AppKit only, built with `swiftc` and no package manager or dependencies. Keep it that way unless there is a strong reason.
- Match the surrounding style: dense, few comments, shared helpers over copy-paste.
- Animation: frames are the `Pose` enum and must exist as `Resources/<pose>.png`. Everything goes through `play(_:_:)` with a `Priority` (talk > expression > idle), driven by the single 30 fps `tick()`. Do not add separate timers.
- Claude Code integration reads transcripts under the config dirs in user defaults (`configDirs`, default `~/.claude`). Never set `CLAUDE_CONFIG_DIR` to the default dir, because that makes Claude Code report "Not logged in".
- Don't block the main thread with file scans or process launches.

## Art
- The character art is CC BY-NC-SA 4.0 by ZipZipPipe (see `LICENSE-ART`). The code is MIT. Keep the credit and the two licenses separate. No commercial use of the art.
- New frames are exported at 600 px tall into `Resources/`. Clean edges with `tools/defringe.py`.

## Issues and PRs
- Reproduce a bug before fixing it. Review PRs properly, building and running them, before merging or asking for changes.
- Reply in short, friendly English.
- Don't touch global git config.
