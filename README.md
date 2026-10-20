# Lazy

A **free, open-source AI companion for macOS** — a voice assistant that lives in your menu bar: screen-aware, able to actually *do* things (drive apps, create files, open settings), proactive with suggestions, and equipped with mail triage and a desktop sticky board.

## Inspiration

Lazy is an independent, free reimplementation **inspired by [HeyClicky]**, the polished commercial AI companion for macOS. It takes the same ideas — a voice companion at your notch, proactive suggestions, bundled skills, a desktop sticky board, mail triage with drafted replies — and rebuilds them from scratch for **$0**: a free Gemini API tier as the brain, with your own local [opencode](https://opencode.ai) server as the fallback. Lazy is not affiliated with, endorsed by, or connected to HeyClicky.

## What it does

- **Voice + chat companion** — hold `ctrl+option` to talk, `fn+control` to dictate; replies are spoken aloud (ElevenLabs while its free quota lasts, then the macOS system voice)
- **Screen awareness** — attach a screenshot, or let Lazy see your screen to answer "what am I looking at?"
- **Agent + GUI runs** — "create a folder on my desktop called receipts" → it runs the commands; "open System Settings and go to the Wi-Fi pane" → it drives the UI, with a yes/no confirm before anything sends, deletes, or purchases
- **GUIDE walkthroughs** — "show me how to…" turns into numbered, on-screen step-by-step tutoring
- **Proactive suggestions** — break reminders, overdue routines, and app-usage insights (Focus/DND aware, quiet hours respected)
- **Mail triage** — connect Gmail or Outlook: urgency + school detection, meeting reminders on the sticky board, macOS banners for urgent mail, and draft replies you approve before they're sent
- **Desktop sticky board** — todos, reminders, and mail cards on a paper note that sits under your windows and never covers your work
- **Skills** — 38 bundled skills plus your own personal skills, injected into the brain's context on demand
- **Personas** — Lazy (default), Pip, Sable, and Juno: same brain, different temperament

## Requirements

- macOS 14.2 or newer (Intel or Apple Silicon)
- Xcode (the app is built with `Cmd+R`)
- Optional: a free Gemini API key from [Google AI Studio](https://aistudio.google.com) — without one, the local opencode server handles the brain
- macOS permissions, requested on first run: Microphone, Screen Recording, Accessibility, Speech Recognition

## Getting started

```sh
git clone <this repo>
open Lazy.xcodeproj   # then press Cmd+R in Xcode
```

Optional — install the Gemini key (keeps it out of the repo, `600` perms):

```sh
mkdir -p ~/Library/Application\ Support/com.yourcompany.leanring-buddy
printf '%s' 'YOUR_FREE_GEMINI_KEY' > ~/Library/Application\ Support/com.yourcompany.leanring-buddy/gemini-api-key
chmod 600 ~/Library/Application\ Support/com.yourcompany.leanring-buddy/gemini-api-key
```

Then talk to it: hold `ctrl+option`, say "turn on dark mode" — it's on before you release the key.

## Notes

- **Strictly $0**: free tiers and local services only — no paid API, no subscription, no telemetry account.
- The built app is **Lazy.app**; the Xcode project/target is internally still named `Clicky` (legacy), and the bundle id is deliberately kept stable so macOS permissions carry over across builds.
- It's a menu-bar app: no Dock icon, no login-item requirement (both togglable in Settings).

## Credits

- **HeyClicky** — the commercial macOS AI companion that inspired this project.
- **hermes skills** — MIT © Nous Research, adopted with attribution (see [NOTICE.md](NOTICE.md)).
- **Patrick Hand** — the handwriting font, SIL Open Font License.

## License

[MIT](LICENSE) — free to use, modify, and share.
