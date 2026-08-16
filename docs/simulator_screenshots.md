# Capturing store screenshots on the iOS Simulator

Written 2026-08-16, after capturing the build-24 set. Read this before re-shooting —
the obvious approach does not work and the workaround is not guessable.

## The one thing that will waste your afternoon

**Synthetic mouse clicks do not reach the Simulator.** Not via AppleScript
`click at`, not via `CGEventPost` to the session tap, not via `CGEventPostToPid`.
The cursor visibly moves to the right pixel (verified by reading it back with
`CGEventGetLocation`) and the process is Accessibility-trusted — the click is
simply never delivered to the simulated screen. This was confirmed against a
freshly `erase`d device on a clean SpringBoard, so it is not a wedged simulator.

**Keyboard events DO reach it.** So the entire capture flow is keyboard-driven.

## Driving the app with the keyboard

Flutter's own focus traversal handles almost everything, and — importantly — it
draws **no visible focus ring**, so screenshots come out clean:

| Key | Code | Does |
|---|---|---|
| Tab / Shift-Tab | 48 | Move focus. Reading order: app-bar leading, actions, then body top-to-bottom |
| Space | 49 | Activate the focused button |
| Return | 36 | Commits a text field (dismisses the keyboard) — it does **not** press the button |
| Escape | 53 | Pops a Flutter dialog (`DismissIntent`). This is how you back out of a wrong tap |
| Page Down | 121 | Scrolls the page. This is the only way to reach below the fold |
| Down arrow | 125 | Moves the highlight inside an open dropdown |

Type with `keystroke "..."`. Tab into the field first; do not press Return
expecting it to submit a form.

A dropdown needs Space to open, then N× Down, then Return. The state picker is
alphabetical, so **NY is 32 downs from AL**.

Counting tabs is guesswork, so screenshot after each step rather than chaining a
long sequence. Some Material widgets *do* paint a faint focus highlight (the
app-bar buttons and the "Report a problem" chip both do) — if one appears in a
shot, terminate and relaunch the app and take it again before touching anything.

## The notification permission dialog — the real blocker

It fires right after login and it is an **iOS system alert**, not a Flutter
dialog: Escape, Return, and Space all bounce off it, and clicks don't work. There
is no `xcrun simctl privacy` service for notifications (`grant all` does not cover
it).

**The way through is iOS Full Keyboard Access**, which gives system alerts a real
focus ring that Tab and Space can drive. It cannot be toggled from the UI without
a click, but it can be written straight into the device's preferences while it is
shut down:

```bash
MAX=<device-udid>
xcrun simctl shutdown $MAX
P=~/Library/Developer/CoreSimulator/Devices/$MAX/data/Library/Preferences/com.apple.Accessibility.plist
/usr/libexec/PlistBuddy -c "Set :FullKeyboardAccessEnabled true" "$P"
xcrun simctl boot $MAX
```

Then Tab rings "Don't Allow", a second Tab moves to "Allow", and Space presses it.

**FKA has to go back off before you shoot**: it breaks text entry into Flutter
fields (Tab moves the ring instead of placing the caret), and it paints a bright
blue ring over whatever is focused. So the order is:

1. FKA **off** → launch → log in (Tab, type, Tab, type, Tab ×3, Space on Log In).
2. FKA **on**, reboot. The Supabase session survives a reboot, so the app comes
   back logged in and the alert re-appears. Dismiss it with Tab, Tab, Space.
3. FKA **off**, reboot. Permission is now granted, so the alert is gone for good
   and every later launch is clean.

Only `simctl erase` loses the login and the granted permission. Reboots are safe.

## Device and status bar

iPhone 17 Pro Max screenshots come out **1320×2868**, which is one of Apple's two
accepted 6.9" sizes — upload with no resizing. Shut down every other simulator
first, or AppleScript's `window 1` targets the wrong one.

Pin the status bar to Apple's convention, and **re-apply it after every boot,
launch, and long wait** — it silently reverts:

```bash
xcrun simctl status_bar $MAX override --time "9:41" \
  --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
```

## Google Play needs different files

Play rejects any screenshot whose long side is more than **twice** the short side.
1320×2868 is 2.17×, so the raw iOS captures are **not** usable. Separately, Play
wants **9:16** for an app to be eligible for promotional placement.

`tools/pad_for_play.py` clears both at once by centering the capture on a
**1620×2880** canvas (exactly 9:16) and stretching each edge row and column
outward to fill the margin — a flat fill leaves visible bars across the navy app
bar, edge extension is seamless.

    python3 tools/pad_for_play.py docs/store/ios docs/store/play
