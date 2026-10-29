# Talk2Me

Hold Fn, speak, release: your words appear, cleaned up by Claude, in whatever app you are typing in.

Talk2Me is a small macOS menu-bar app. Speech is turned into text on your Mac with Apple's
built-in recognizer, so audio never leaves the machine. The text is then cleaned up by Claude
(punctuation, filler words, spoken formatting such as "new paragraph") and pasted into the
focused text field. Your clipboard is put back afterwards.

## Download and install

Requires macOS 26 or later on an Apple silicon Mac.

1. Download **[Talk2Me.zip](https://github.com/Moen01/talk2me/releases/latest/download/Talk2Me.zip)**
   (or the [disk image](https://github.com/Moen01/talk2me/releases/latest/download/Talk2Me.dmg)).
   These links always give the newest version; see all versions on the
   [releases page](https://github.com/Moen01/talk2me/releases).
2. Open the disk image and drag **Talk2Me** to **Applications**.
3. Open Talk2Me. Because this build is not notarized by Apple yet, macOS blocks it the first
   time: click **Done**, then open **System Settings > Privacy & Security**, scroll down to
   "Talk2Me was blocked" and click **Open Anyway**.
4. The setup guide walks you through permissions, connecting Claude and choosing your shortcut,
   and lets you try a dictation before you finish. Reopen it any time from the menu-bar icon
   with **Setup Guide…**.

## How to use it

| Action | What happens |
| --- | --- |
| Hold the dictation key (Fn by default), speak, release | Records while held, then transcribes, cleans up and pastes |
| Double-tap the hands-free key (Fn by default) | Hands-free mode: keeps recording without holding |
| Enter, or the key again, in hands-free mode | Finishes and pastes |
| Escape in hands-free mode | Discards the recording |
| A quick single tap, or the key used with another key | Ignored, so Fn+Delete and similar shortcuts still work |

The menu-bar icon shows the current state and the result of the last dictation.

### Choosing your keys

In Settings > Hotkey, pick the key you hold to dictate and the key you double-tap for
hands-free mode (or turn hands-free off). Choose a preset (Fn, Right Option, Right Command,
Right Control, Left Option, Left Command) or click **Record a key…** and press any key.

- Left and right modifiers are separate, so Right Option can dictate while Left Option still
  types special characters.
- A regular key such as F13 is taken over completely: it won't type in other apps.
- Escape, Enter and Caps Lock can't be used, because Escape and Enter control hands-free mode
  and Caps Lock toggles instead of holding.

### Dictionary

In Settings > Dictionary, add the words Talk2Me must write your way. Type what you say under
**Speech word** and what must be written under **Dictionary**:

| Speech word | Dictionary |
| --- | --- |
| PR | Pull Request |
| PRs, PR's | pull requests |
| arythma | Artitma |

Separate more than one speech word with commas. Talk2Me replaces whole words only, in any letter
case, so "pr" becomes "Pull Request" but "press" stays. The dictionary words are also given to the
speech recognizer, so it hears them more often, and to Claude, so cleanup keeps them as written.

### Snippets

In Settings > Snippets, make voice commands. Say only the phrase and release the key: Talk2Me
does the action instead of pasting the words.

| When I say | Action |
| --- | --- |
| open jira | **Open link**: `jira.catacloud.no` (https:// is added when missing) |
| start standup | **Run shortcut**: the name of a shortcut in the Shortcuts app |
| my address | **Paste text**: any text, also more than one line |

Upper/lower case and punctuation do not matter, but the phrase must be the whole dictation:
"can you open jira" pastes the sentence as normal. A shortcut can do almost anything, including
running a shell script, so use **Run shortcut** for tasks.

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

## Build from source

```sh
./scripts/build-app.sh
open build/Talk2Me.app
```

On first launch the setup guide asks for two permissions:

1. **Microphone**: to hear you while you hold the shortcut.
2. **Accessibility** (System Settings > Privacy & Security > Accessibility): to notice the
   shortcut key and to paste.

To stop Fn from also opening the emoji picker, leave "Hide Fn from other apps" on in Settings,
or set System Settings > Keyboard > "Press globe key" to "Do Nothing".

### Making a release

Every push to `main` makes a release: `.github/workflows/release.yml` runs the tests, builds the
app and publishes `Talk2Me.zip`, `Talk2Me.dmg` and `SHA256SUMS` as a new GitHub release.
Changes to Markdown files only do not make a release.

The version goes up by one each time (0.1.0, 0.1.1, 0.1.2, …). To jump, for example to 0.2.0, set
`CFBundleShortVersionString` in `Resources/Info.plist` to that version in the same push.
`scripts/next-version.sh` prints the version the next release will get.

To build the same files locally:

```sh
./scripts/package-release.sh   # writes dist/Talk2Me.zip, Talk2Me.dmg and SHA256SUMS
```

Settings shows a blue "Update to x.y.z" button when GitHub has a newer release. The check reads
the public GitHub API, so it only works while the repository is public.
`scripts/make-icon.sh` redraws `Resources/AppIcon.icns`.

### Signing

macOS ties Talk2Me's Microphone and Accessibility permissions to its signing certificate, so
every build is signed with the same self-signed **Talk2Me Signing** certificate. Then the
permissions survive rebuilds and updates, and the in-app updater only installs a build signed
with that certificate. It is not an Apple Developer ID, so a downloaded copy still shows
"Apple could not verify" the first time; updates from inside the app do not.

- Locally the certificate lives in its own keychain in
  `~/Library/Application Support/Talk2Me Signing/` (with its password and a `.p12` backup), and
  `scripts/build-app.sh` signs with it. The keychain must be on the search list
  (`security list-keychains -d user`).
- The release workflow loads the same `.p12` from the `SIGNING_CERT_P12` and
  `SIGNING_CERT_PASSWORD` repository secrets, and fails without them.
- Without the certificate, `build-app.sh` signs ad-hoc, and macOS asks for both permissions
  again after every rebuild.

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
