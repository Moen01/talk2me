# Talk2Me

Hold Fn, speak, release: your words appear, cleaned up by Claude, in whatever app you are typing in.

Talk2Me is a small macOS menu-bar app. Speech is turned into text on your Mac with Apple's
built-in recognizer, so audio never leaves the machine. The text is then cleaned up by Claude
(punctuation, filler words, spoken formatting such as "new paragraph") and pasted into the
focused text field. Your clipboard is put back afterwards.

## How to use it

| Action | What happens |
| --- | --- |
| Hold Fn, speak, release | Records while held, then transcribes, cleans up and pastes |
| Tap Fn twice | Hands-free mode: keeps recording; tap Fn again to finish |
| Escape in hands-free mode | Discards the recording |
| A quick single tap, or Fn with another key | Ignored, so Fn+Delete and similar shortcuts still work |

The menu-bar icon shows the current state and the result of the last dictation.

## Connecting to Claude

Pick a backend in Settings:

- **Claude Code (your subscription).** Talk2Me runs your own Claude Code install, the way
  [T3 Code](https://github.com/pingdotgg/t3code) does. Sign in once in Terminal with
  `claude auth login`; Talk2Me never sees your Claude login. Anthropic does not allow third-party
  apps to offer Claude.ai sign-in themselves, and its terms say subscription limits assume ordinary,
  individual use, so treat this as a personal-use option.
- **Claude API key.** Paste a key from [platform.claude.com](https://platform.claude.com); it is
  stored in the macOS Keychain and usage is billed to that key.
- **Off.** Pastes the raw transcript.

The model (Claude Opus 5.5, Sonnet 5.5 or Haiku 5.5) is chosen in Settings. If cleanup fails or
takes longer than the timeout (15 s by default), the raw transcript is pasted instead, so a
dictation is never lost.

## Requirements

- macOS 26 or later on Apple silicon
- Xcode 26 or later (Swift 6.2) to build
- For the Claude Code backend: Claude Code 2.1.280 or later to use Opus 5.5 (`claude update`,
  or `brew upgrade claude-code` for a Homebrew install)

## Build and run

```sh
./scripts/build-app.sh
open build/Talk2Me.app
```

On first launch, grant:

1. **Accessibility** (System Settings > Privacy & Security > Accessibility): needed to watch
   the Fn key and to paste.
2. **Microphone**: asked automatically on first launch.

To stop Fn from also opening the emoji picker, leave "Hide Fn from other apps" on in Settings,
or set System Settings > Keyboard > "Press globe key" to "Do Nothing".

The build is ad-hoc signed, so macOS asks for Accessibility access again after each rebuild.
For a stable signature, create a code-signing certificate and build with
`SIGN_IDENTITY="Your Certificate Name" ./scripts/build-app.sh`.

## Languages

Dictation uses Apple's on-device `DictationTranscriber`, which supports 54 locales on
macOS 27, including Norwegian Bokmål (`nb_NO`) and English. The language is chosen in Settings;
macOS downloads a language's speech files the first time it is used.

## Developing

```sh
swift test                      # unit tests for the core logic
swift build --product talk2me-bench
.build/debug/talk2me-bench cleanup --backend claude-code --model sonnet --runs 2
.build/debug/talk2me-bench transcribe recording.m4a --locale nb_NO
```

`talk2me-bench cleanup --backend api` reads `ANTHROPIC_API_KEY` from the environment.

| Path | Contents |
| --- | --- |
| `Sources/Talk2MeCore` | Hotkey state machine, on-device transcription, Claude cleanup backends and router |
| `Sources/Talk2Me` | The menu-bar app: event tap, microphone, paste, settings |
| `Sources/Talk2MeBench` | Command-line tool to time backends and transcribe files |
| `Tests/Talk2MeCoreTests` | Swift Testing suites |

## Privacy

- Audio is held in memory while recording and discarded after transcription; it is never saved.
- Only the transcript text is sent to Claude, through the backend you choose.
- Talk2Me sends no telemetry.
