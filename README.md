# claude-pixel-pet

A small pixel-art Claude that lives on your macOS desktop. You can chat with it, and it keeps an eye on your Claude Code sessions.

一只住在 macOS 桌面上的像素 Claude：点它可以聊天，它也会盯着你的 Claude Code 在干什么。

<img src="docs/preview.png" width="220" alt="preview">

## What it does

- **Chat.** Click the pet and type; press Enter to send and Esc to close. Replies come from a persistent headless Claude Code session (`claude -p --resume`) with all tools disabled. Use "New chat" in the menu to start over.
- **Claude Code activity.** While a session is working, a small label above the pet's head shows the project and the current step (for example `my-app: Bash · Run tests`). When a task that ran for more than 20 seconds finishes, the pet tells you.
- **Usage.** The menu-bar ✦ shows today's output tokens. The menu breaks usage down per account (output, input including cache, number of sessions) and shows the context size of the latest session.
- Drag the pet to move it. The transparent area around the character is click-through. Sizes are Small, Medium and Large. It can stay on top, shows on every desktop, and has no Dock icon.

Activity and usage come from reading the local transcripts in `~/.claude/projects/**/*.jsonl`. Nothing is sent anywhere. The only network traffic is the chat, which goes through your own `claude` CLI.

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
| `Resources/` | sprite frames: mouth closed / half / open |
| `tools/defringe.py` | cleans leftover white background out of the hair in the sprites (numpy, scipy, Pillow) |

## License

- **Code** (`main.swift`, `build.sh`, `tools/`): MIT. See `LICENSE`.
- **Character art** (`Resources/`, `docs/preview.png`): derived from the Claude character design by **ZipZipPipe (胖次狐)**, which is published under [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/). The 3-heads-tall pixel version is a derivative work under the same license. **No commercial use.** See `LICENSE-ART`.

This is a fan project. It is not affiliated with or endorsed by Anthropic. "Claude" is a trademark of Anthropic.
