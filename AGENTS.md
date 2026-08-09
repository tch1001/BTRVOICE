# Notes for agents working on this repo

## Always `git pull` first

**Before you touch anything, run `git pull`.**

This repo is worked on from more than one machine — a macOS laptop (the Swift app in
`Sources/`) and an Ubuntu box (the Linux port in `linux/`). Either side may have been
committed and pushed since your last look, and the two ports share the README, the
protocol contracts, and the feature vocabulary. Starting from a stale tree means
re-deriving decisions that were already made, or worse, silently reverting them in a
merge.

```bash
git pull --rebase
```

Do this at the start of every session, not just before you push.

## Layout

| Path | What it is |
| --- | --- |
| `Sources/BtrVoice/` | The macOS app (Swift 6 / SwiftUI, ~6.4k lines). Built with `./build.sh`. |
| `linux/` | The Ubuntu/X11 port (Python). See `linux/README.md`. |
| `Resources/`, `tools/` | macOS packaging: entitlements, Info.plist, signing cert helper. |

The two ports are deliberately parallel in structure — `Speech/`, `Dictation/`,
`Inject/`, `UI/` on the Swift side map onto `stt/`, `buffer.py`, `inject.py`, `ui/`
on the Python side. When you add a concept to one, check whether the other wants it
too, and keep the names the same so the correspondence stays obvious.

## The core invariant, on both platforms

BtrVoice never inserts text through an accessibility API. It transcribes into its
**own** buffer, lets the user review it, and only on an explicit commit replays the
text as **synthetic keyboard events** — `CGEvent` on macOS, XTEST (via `xdotool`) on
X11. Two things follow, and breaking either one breaks the product:

1. **The panel must never steal focus.** If it does, the target window is lost and the
   commit types into the wrong place. macOS uses a non-activating `NSPanel`; the Linux
   port uses Qt's `WA_ShowWithoutActivating` + `Qt.WindowDoesNotAcceptFocus`.
2. **The previously-focused window must be tracked** so the commit can restore focus to
   it first. `Inject/TargetTracker.swift` and `linux/btrvoice/inject.py` both exist for
   this and for no other reason.
