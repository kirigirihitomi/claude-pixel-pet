# claude-pixel-pet

A small pixel-art Claude that lives on your macOS desktop. You can chat with it, and it keeps an eye on your Claude Code sessions.

一只住在 macOS 桌面上的像素 Claude：点它可以聊天，它也会盯着你的 Claude Code 在干什么。

<img src="docs/preview.png" width="220" alt="preview">

## What it does

- **Chat, or drive a real session.** Click the pet and type; press Enter to send and Esc to close. By default you're in "Pet chat", a session of its own with no tools. Use "Switch session" in the menu to attach to any recent Claude Code session, or start a new one in a folder. The pet then runs Claude Code there with its normal tools. When a tool needs approval, a card pops up above the pet's head with **Allow / Deny**. Your own permission settings still apply. "Stop" interrupts the current turn.
  Under the hood this is the same stream-json protocol the IDE extensions use: one long-lived `claude -p --input-format stream-json --output-format stream-json --permission-prompt-tool stdio` process per attached session.
  Attaching to a session that is still open in a terminal or IDE forks it: both continue from the same history.
- **Claude Code activity.** While a session is working, a small label above the pet's head shows the project and the current step (for example `my-app: Bash · Run tests`). When a task that ran for more than 20 seconds finishes, the pet tells you.
- **Open in Terminal.** Lists the Claude Code sessions from the last 7 days (project, title, time). Pick one and Terminal opens in that directory and runs `claude --resume` for it.
- **Usage.** The menu-bar ✦ shows today's output tokens. The menu breaks usage down per account (output, input including cache, number of sessions) and shows the context size of the latest session.
- **Usage panel.** Right-click the pet for a panel with your plan limits per account (5-hour and weekly, with Opus / Sonnet when your plan has them), the same percentages and reset times as `/usage` in Claude Code, plus today's tokens and what is running now. The first time, macOS asks whether ClaudePet may read Claude Code's login from the keychain; choose Always Allow.
- **Pixel animation.** She blinks every few seconds. Now and then she reads her book, and very rarely she yawns. She smiles when a Claude Code task finishes and looks surprised when a permission card pops up. Every pose is a full pixel-art frame with only the eyes and mouth changed, so nothing gets stretched.
- Drag the pet to move it. The transparent area around the character is click-through. Sizes are Small, Medium and Large. It can stay on top, shows on every desktop, and has no Dock icon.

Activity and usage come from reading the local transcripts in `~/.claude/projects/**/*.jsonl`. Nothing is sent anywhere. Network traffic is the chat, which goes through your own `claude` CLI, and, while the usage panel is open, at most one request a minute per account to `api.anthropic.com/api/oauth/usage` (the endpoint Claude Code's own `/usage` calls) with that account's login. The token is read from the keychain and not stored anywhere else. That endpoint is undocumented, so the plan limits can stop working after a Claude Code update.

## Build

Requirements: macOS 14 or later, the Xcode command line tools (`xcode-select --install`), and [Claude Code](https://docs.claude.com/en/docs/claude-code) on your `PATH` for chat.

```sh
./build.sh      # builds build/ClaudePet.app, installs it to ~/Applications and launches it
```

To start it at login, add it in System Settings → General → Login Items.

### Several Claude Code accounts

If you keep more than one config dir (for example with `CLAUDE_CONFIG_DIR`), list them in order. The first one is also used for chat.

```sh
defaults write io.github.kirigirihitomi.claude-pixel-pet configDirs -array ~/.claude-personal ~/.claude
```

## Files

| | |
|---|---|
| `main.swift` | the whole app (AppKit, no dependencies) |
| `build.sh` | compiles with `swiftc` and packages the `.app` |
| `Resources/` | sprite frames: mouth closed / half / open, plus face poses (blinks, reading, yawn, smile, surprised) |
| `tools/defringe.py` | cleans leftover white background out of the hair in a cut-out sprite; `--face` protects a region, `--fill-face-holes` repairs punched-out eye whites (numpy, scipy, Pillow) |

## License

- **Code** (`main.swift`, `build.sh`, `tools/`): MIT. See `LICENSE`.
- **Character art** (`Resources/`, `docs/preview.png`): derived from the Claude character design by **ZipZipPipe**, which is published under [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/). The 3-heads-tall pixel version is a derivative work under the same license. **No commercial use.** See `LICENSE-ART`.

This is a fan project. It is not affiliated with or endorsed by Anthropic. "Claude" is a trademark of Anthropic.
