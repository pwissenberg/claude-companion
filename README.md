# Claude Companion

**A floating Claude.ai window for macOS: press ⌥Space over any app to ask, press it
again to dismiss.** Built because Claude has no equivalent of the ChatGPT desktop
popup, and switching to a browser tab breaks the thread of whatever you were doing.

Press **⌥Space** (Option+Space) anywhere to summon a small floating window with
your Claude.ai account inside it. Press **⌥Space** again (or **Esc**) to dismiss it.

It's a native, lightweight AppKit app: a borderless floating `NSPanel` hosting a
`WKWebView` pointed at `claude.ai`. Because it embeds the real web app and uses a
persistent cookie store, you log in once with your normal account and stay logged in.

## Build & run

No Xcode required - just the Command Line Tools Swift toolchain.

```bash
./build.sh --install # build, install to /Applications, and launch it there
./build.sh --run     # build and (re)launch from ./build.noindex, without installing
./build.sh           # build only
./test.sh            # run the unit tests
```

`--install` is what makes it a real app: `/Applications` is the only location Spotlight
indexes by default, and the only one `SMAppService` will register a login item from. It
quits any running copy first - two instances would fight over the ⌥Space hot key, and
only one can win it - and re-signs after copying, since that invalidates the ad-hoc
signature.

The build directory is named `build.noindex` because macOS skips indexing directories
with that suffix. Otherwise Spotlight offers two identical "Claude Companion" entries
and you can't tell which one you're launching.

### Starting and stopping

| | |
|--|--|
| Start | Spotlight → "Claude Companion", or `open -a "Claude Companion"` |
| Stop | menu bar 🗨️ → **Quit**, or `pkill -f "MacOS/ClaudeCompanion"` |
| Start automatically at login | menu bar 🗨️ → **Start at Login** |

The app has **no Dock icon** and no ⌘Q, by design - it's a background companion, so
everything lives in the menu-bar menu.

**Editing shortcuts are handled by the window itself.** AppKit turns ⌘V into a `paste:`
action by matching it against the Edit menu's key equivalents; an app with no main menu
never gets that match, so ⌘V, ⌘C, ⌘X, ⌘A and ⌘Z are silently dropped - you can type
into Claude but not paste. `CompanionPanel.performKeyEquivalent` dispatches those
actions down the responder chain instead, which needs no menu to exist.
`claudecompanion://test-paste` exercises the real keystroke path end to end.

**Start at Login** uses `SMAppService`, which needs no helper bundle or permission
prompt; if registration fails it says so in an alert rather than silently doing
nothing, and points at System Settings → General → Login Items.

## Distributing via Homebrew

A Mac app is distributed as a **Cask**, which needs three things: a downloadable
artefact at a stable URL, a cask definition, and a tap to serve it from.

```bash
./build.sh --dist     # writes dist/ClaudeCompanion-<version>.zip + dist/claude-companion.rb
```

The zip is built with `ditto`, not `zip`, because that preserves the bundle's symlinks,
extended attributes and code signature - a plain zip mangles them and the app fails to
launch. The cask is generated with the freshly computed sha256, so it can never drift
from the artefact it describes.

Then:

```bash
gh release create v0.1.0 dist/ClaudeCompanion-0.1.0.zip --repo pwissenberg/ui-claude \
    --title "Claude Companion 0.1.0" --notes "..."

# In a tap repo named homebrew-tap:
cp dist/claude-companion.rb Casks/claude-companion.rb

brew install --cask pwissenberg/tap/claude-companion
```

### Two things that have to be settled first

**The repository is private.** Homebrew downloads the release asset anonymously, so the
repo (or at least the asset) has to be publicly reachable. A release asset on a private
repo needs a token, which a cask cannot supply.

**The app is ad-hoc signed** (`Signature=adhoc`, no Team ID). That is fine for a locally
built copy, but macOS quarantines anything *downloaded*, and Gatekeeper refuses an
ad-hoc-signed bundle with "the app is damaged and can't be opened". Two ways out:

- **Sign and notarise properly** - an Apple Developer ID ($99/yr), then
  `codesign --sign "Developer ID Application: ..." --options runtime` and
  `xcrun notarytool submit`. This is the only route where the app just opens.
- **Have users bypass quarantine** - `brew install --cask --no-quarantine ...`, or
  `xattr -dr com.apple.quarantine "/Applications/Claude Companion.app"`. Free, but every
  user has to know to do it, and it trains people to disarm a security check.

Note also that `homebrew/cask` itself has notability requirements a brand-new repository
will not meet, so a personal tap is the practical route either way.

## Usage

| Action | How |
|--------|-----|
| Show / hide the window | **⌥Space** |
| Dismiss the window | **Esc** |
| Move the window | drag anywhere on it |
| Send a message | **Enter** (**⇧Enter** for a newline) |
| Start a new conversation | **⌘N**, the **New** button in the header, or the menu |
| See how much of your plan is left | glance at the menu bar; click it for every limit |
| Reload / Quit | menu-bar icon |
| Stop it following the active window | menu bar → **Follow Active Window** |
| Make conversations translucent too | menu bar → **Translucent Chat** |
| Put the window back in its default spot | menu bar → **Reset Position** |
| Toggle from a script | `./toggle.sh` or `open -g "claudecompanion://toggle"` |

The URL scheme (`claudecompanion://toggle`, `://show`, `://hide`) makes the window
bindable from Raycast, Shortcuts, or Alfred.

## Architecture

| File | Role |
|------|------|
| `main.swift` | Boots `NSApplication` as an accessory (menu-bar-only) app; installs an uncaught-exception logger. |
| `AppDelegate.swift` | Builds the status item, floating panel, and web view; hot key + URL-scheme actions. |
| `CompanionPanel.swift` | Borderless `NSPanel` subclass that can take keyboard focus + Esc-to-dismiss. |
| `ActiveWindow.swift` | Finds the window the user is working in, without needing any TCC permission. |
| `WebChrome.swift` | Injected CSS for the translucent, single-conversation look, plus DOM probes. |
| `PopupWindow.swift` | Real secondary window for `window.open` sign-in popups. |
| `GlobalHotKey.swift` | System-wide hot key via Carbon (no Accessibility permission needed), with fallback combos. |
| `Log.swift` | stderr + `~/Library/Logs/ClaudeCompanion.log` logging. |
| `Usage.swift` | Plan-usage model: decoding claude.ai's usage reply, and its wording. |
| `UsageMonitor.swift` | Polls plan usage through the signed-in web view, for Claude Code's organization. |
| `UsageIndicator.swift` | The menu-bar ring gauge and the per-limit menu rows. |
| `build.sh` | Compiles with SwiftPM and assembles a signed `.app` bundle. |
| `test.sh` | Runs the unit tests, with or without Xcode installed. |
| `Tools/make-icon.swift` | Draws the app icon and writes `Resources/AppIcon.icns`. |

### Appearance

The panel is a translucent, single-conversation view rather than the full claude.ai app:

- An `NSVisualEffectView` (`.hudWindow`, `.behindWindow`) provides the macOS blur,
  with a 22pt continuous ("squircle") corner radius and a hairline white border so the
  panel still has definition against a light backdrop.
- **The blur is clipped with `maskImage`, not just a layer `cornerRadius`.** A layer
  radius rounds the view's *contents*; the backdrop blur keeps sampling the full square
  window bounds, which paints a bright halo around the panel - very visible over a light
  background. `maskImage` masks the effect itself. The mask is a small resizable image
  with cap insets, so one image fits any panel size.
- That halo is invisible to every form of capture: `cacheDisplay` renders the hierarchy
  offscreen, and even `CGWindowListCreateImage` of the live window reports `alpha 0`
  there, because the blur is derived from a backdrop the capture doesn't contain. It can
  only be seen on screen.
- Three separate things paint an opaque backdrop, and **all** of them have to be
  cleared or the panel stays solid:
  1. `webView.underPageBackgroundColor = .clear`.
  2. `_setDrawsBackground:` - on macOS the clear `underPageBackgroundColor` above is
     *not* sufficient on its own; WKWebView keeps painting an opaque backdrop. This
     is private API, so it is probed with `responds(to:)` first and logged if absent,
     rather than risking a crash on a future macOS.
  3. CSS for `body`, `main.dframe-content`, **and** a full-bleed
     `div.pointer-events-none.absolute.inset-0` overlay that sits on top of `main`.
- The sidebar, recents, pinned lists, and app header are hidden, leaving just the
  conversation.

### Chat view

Once a conversation exists the window is only 440pt wide, so claude.ai's own chrome
needs trimming to stop it colliding with the content and the rounded corners:

- The footer disclaimer (`div.sticky.bottom-0 div.text-muted.text-center`) is hidden.
  It sits below the composer, where there is no room for it.
- The composer gets 10pt of bottom padding. Flush against the window edge, its own
  rounded box is cut by the 22pt window corners.
- Transient overlays such as "Want to be notified when Claude responds?" cover the
  reply in a window this small. They carry no stable hook, so `dismissBanners` matches
  them by text on every tick - they appear mid-response, long after load, so a
  one-shot check at load time would miss them. Two rules keep that safe:
  - **Never hide an element containing the composer.** claude.ai renders this banner
    *inside* the composer's own wrapper, so matching on text alone takes the composer
    down with it and leaves the conversation with no way to reply.
  - **The hiding is reversible.** Once the banner's text is gone the element is
    ordinary again, so the class is removed. Hiding permanently strands whatever that
    element holds next.

**A conversation looks like the compact bar it grew out of** - same blur, same surface,
with the composer as a light translucent inset rather than claude.ai's opaque panel.
Switching to a solid black window once a question was asked made the two states read as
different apps.

The cost is that claude.ai's scrims and overlays are drawn to fade into its own opaque
surface, so they have to be neutralised one by one:

- claude.ai fades the transcript out towards the composer with gradient scrims built
  for its own solid background. Over a translucent window those read as a heavy black
  band. `clearScrims` blanks them, matching on: a gradient background, at least 60% of
  the viewport wide, at least 40pt tall, and no more than 40 characters of text - the
  band contains claude.ai's "Quick answer" button, so requiring it to be empty would
  skip the element that needs clearing.
- The composer is **sticky**, so the transcript scrolls underneath it. claude.ai hides
  that with a scrim fading to its own opaque surface; removing that scrim without
  replacing it leaves message text running straight through the composer. The footer
  gets a `backdrop-filter` blur instead, doing the work a macOS toolbar's does. A
  darkening fade was tried alongside it and removed: it read as a shadow smeared
  across the bottom of the panel, and the blur alone is enough.
- Muted text - the "Thinking…" line, timestamps, the effort label - is
  `rgb(137,135,129)`, chosen for a near-black surface. The translucent panel measures
  about `rgb(129,129,129)`, so it lands at roughly **1.02:1** contrast: the same colour
  as its background. `brightenMuted` measures luminance and lifts anything below the
  threshold. It measures rather than matching a class, because that colour comes from
  neither `--text-400` nor a `text-muted` utility - overriding the token provably
  changed nothing.
- **Translucent Chat** in the menu turns this off, restoring claude.ai's native opaque
  surface. Every scrim then blends correctly by construction, so it is the
  guaranteed-clean fallback if a new artefact ever slips through.
- Scrims are tagged **once**, like `.cc-surface`. The rule blanks the gradient, so
  re-evaluating would find no gradient, untag it, and flip forever.
- The sweep checks `::before` and `::after` as well as the element itself. A fade is
  commonly drawn with `before:bg-gradient-*`, which `getComputedStyle(el)` does not
  report - so an element-only check is blind to exactly the scrims that matter.
- The default scrollbar is replaced with a 6pt translucent one.

### Composer spacing

claude.ai puts a 12pt gap between the input and the controls row, with 14pt margins
around both - proportions for a full-width window, which leave an obvious hole in a
440pt panel. Reduced to 6pt and 10pt.

The input row itself is deliberately untouched: it is sized by its content, so it still
grows as a message wraps. A `min-height: 0` was tried on it first and removed - the row
was already `min-height: 0px`, and its height was simply the draft it contained.

### Horizontal space

Five nested containers inset the composer - the pane scroller's 8pt, a column's 4pt,
the composer surface's 8pt margin, the inner column's 10pt, and a 6pt row padding -
costing 36pt before the text starts and 30pt after it. That is 15% of a 440pt window
spent on margins sized for a full-width browser.

Trimmed to 22pt on both sides, widening the text from 374pt to 396pt. The outermost 8pt
is deliberately kept so text never touches the window edge.

The two sides also differed: the input row carries 6pt of padding on the left and none
on the right, which pushed the text off-centre and made the composer look badly fitted
around it. Zeroing that squares the sides up and gains the 6pt as line width.

### Enter to send

claude.ai's composer variant here (`composer-card-latch = classic`) sends on
**⇧Enter** and exposes no preference to change it, so the injected script handles the
key itself: Enter clicks `[data-testid="chat-input-send"]`, ⇧Enter inserts a newline.

- Handled in the **capture** phase, so the page's own handler never runs and a message
  cannot be sent twice.
- ⇧Enter is intercepted too, not merely ignored. Ignoring it would leave *both* keys
  sending and nothing inserting a newline.
- An IME mid-composition is left alone (`isComposing`, `keyCode === 229`), where Enter
  accepts a candidate rather than sending.
- With an empty composer the handler stands aside, since there is nothing to send.

`claudecompanion://test-enter` verifies this **without posting anything**: it types into
the composer so the send button becomes enabled, dispatches real Enter and ⇧Enter
events with the handler in dry-run mode, reports what each *would* do, then restores the
draft. Typing and checking must be separate evaluations - the button's enabled state is
React state and does not update within the same turn as the typing that caused it.

### Starting a new conversation

Three routes, all ending in the same `newChat`: the **New** button in the conversation
header, **⌘N**, and the menu-bar item.

- The button is injected into claude.ai's own `#dframe-header-actions-slot`, so it sits
  with the other header controls, and is re-added on every tick because React replaces
  that subtree freely. It **posts a message** rather than navigating itself, so all
  three routes share one code path.
- ⌘N goes through `performKeyEquivalent` like the editing shortcuts - there is no menu
  for AppKit to match it against.
- Starting a new conversation returns the window to the compact composer bar, since the
  page is back at `/new`.

Note that the button and the keystroke reach `newChat` by **different** routes - the
message handler versus the responder chain - so verifying one proves nothing about the
other. Both are exercised by `claudecompanion://test-newchat-button` and
`claudecompanion://test-newchat`.

### Compact mode

With no conversation open, the window collapses to **just the composer** - no greeting,
no icons, no empty space - and expands to full height once a conversation starts, like
the ChatGPT companion.

- The composer is isolated **structurally**: every sibling along its ancestor chain is
  hidden (`WebChrome.layoutJS`). The chain is something the DOM guarantees; the
  Tailwind class names on the greeting and header are not, so hiding by name would be
  the fragile choice.
- **The walk stops at `<main>`.** Above `main` is the app's layout scaffolding,
  including a CSS Grid. Hiding an item inside that grid removes it from grid layout,
  which re-places the surviving item into a content-sized row - and since `main` is
  absolutely positioned and contributes no height, that row collapses to zero,
  taking the whole subtree with it. The result renders *nothing* while still
  reporting a correct 120pt composer rect.
- **No layout overrides on the wrappers.** They aren't needed: once the window is
  only as tall as the composer, `h-screen` is that height too, so the page's own
  layout already fits. Forcing `height: auto` on them collapses `main` to 0x0 and
  every `w-full` descendant with it.
- The page reports the composer's height over a `WKScriptMessageHandler`, and the panel
  resizes to `height + 20`. Its bottom edge stays planted (in Cocoa `origin.y` *is* the
  bottom edge), so it grows upward from its resting position instead of drifting.
- Mode follows the URL: claude.ai uses `/new` until a conversation exists, then
  `/chat/<id>`. Because it's a single-page app, the script polls every 400ms rather
  than relying on load events.
- The isolation re-runs every tick and clears the chain first. claude.ai is a React
  app that replaces subtrees, so an element hidden during an earlier pass can end up
  on the composer's current chain and hide the composer permanently.

**The window frame is the composer's frame.** claude.ai paints its own opaque rounded
panel inside the composer; left alone, that reads as a box inside a box - two borders,
two radii, and the blur reduced to a thin gutter. The compact stylesheet strips that
panel's background, border, radius, and shadow (`.cc-surface`), and `compactPadding` is
`0`, so what you see is a single translucent bar like the ChatGPT companion.

Two feedback loops had to be closed to make this stable, both of the same shape - an
effect that changes its own input:

- `.cc-surface` is tagged **once**. The tag goes to the largest element painting a
  background; making it transparent means it no longer qualifies, so re-evaluating each
  tick moves the tag away, the background returns, and the composer's height flips
  between 118 and 120pt forever.
- `setPanelHeight` ignores changes under `heightTolerance` (5pt). Resizing the window
  re-lays out the page and can shift the measured height by a point or two. A wrapped
  line of text is far larger than the deadband, so real growth still gets through.

```
layout compact: composer 120pt -> panel 140pt
health check: ... compact=true viewport=140 composer=10..130 fits
stray elements: no stray elements
```

## Plan usage

The menu-bar item shows how much of your Claude plan is **left** - a ring beside
the app's symbol plus a percentage, like a battery. It tracks whichever limit you will
hit first (the one claude.ai marks active: usually the 5-hour session, sometimes the
weekly allowance). The percentage turns orange at 25% left and red at 10%, and the
gauge dims once a reading is over five minutes old. Click it for every limit, each with
a bar and its reset time, plus **Usage Details…** for claude.ai's own usage page.

![Usage gauge and menu rows, light and dark](Resources/usage-preview.png)

- **It asks claude.ai, from inside the web view.** `GET /api/organizations/<uuid>/usage`
  is what claude.ai's usage page reads. Fetching it in the page means the request is
  already signed in, same-origin and past Cloudflare; a native `URLSession` request
  would need the cookies copied across and could still be challenged. It runs in the
  `.defaultClient` script world, isolated from claude.ai's own JavaScript.
- **It reads Claude Code's organization, not the web session's.** One account can
  belong to several organizations - a personal Max plan and a team, say - each with
  separate limits, and the web session's last-used one need not be the one Claude Code
  bills. `~/.claude.json` (`oauthAccount.organizationUuid`) names Claude Code's, and is
  re-read on every refresh. Fallbacks, in order: an organization with a personal
  subscription, the web session's last-used organization, any with chat. One that is
  listed but has no plan usage (an API-only organization answers 403) is skipped. The
  menu names the plan, so it is always clear which one is shown.
- **The `limits` list is the source of truth**, with `five_hour` / `seven_day` as a
  fallback. The reply is full of codenamed, experimental keys, so neither shape is
  assumed to be permanent; `UsageTests` pins the parsing against a real reply.
- Refreshed every 60 seconds, when the menu opens, when the window is dismissed (what
  you just asked has counted by then), and on every claude.ai page load. A failed
  refresh keeps the last reading; signing out clears it, since it belonged to a session
  that is gone. With no reading the item is just the symbol, as before.

`claudecompanion://usage` refreshes immediately and logs the reading;
`claudecompanion://render-usage` draws the gauge at every level and the menu rows, in
light and dark, to `/tmp/cc-usage.png`. That replica is the only way to inspect them
pixel by pixel: on current macOS the menu-bar item and its menu are drawn by Control
Center, out of process, so no capture of this app's windows can see them.

## Diagnosing the page

Geometry logs report correct rects **whether or not anything was painted**, so they
cannot tell a layout bug from a rendering one. These two commands can:

```bash
./check.sh                              # inspect the live DOM right now
open -g "claudecompanion://snapshot"    # write what is actually drawn to /tmp
```

`snapshot` writes two PNGs, which separate the layers:

- `/tmp/cc-web.png` - what the *page* renders (via `WKWebView.takeSnapshot`)
- `/tmp/cc-window.png` - the view hierarchy drawn offscreen (`cacheDisplay`)

Neither shows what the **window server** actually composites, so neither can reveal
edge or corner artefacts - `cacheDisplay` renders the same picture whether or not the
defect is present. `claudecompanion://screengrab` captures the real window instead:

- `/tmp/cc-screen.png` - the window's own pixels
- `/tmp/cc-screen-framed.png` - including shadow and framing

Sample the corner pixels rather than trusting the image: transparency renders as white
in most viewers, which looks identical to a white artefact.

`check` logs the injected-style state, the composer's full ancestor chain with each
element's computed size/overflow/position, and any stray chrome floating outside the
composer (the floating "Open sidebar" trigger is a separate `<aside>` that outlives
the sidebar panel itself). `CLAUDE_COMPANION_NO_COMPACT=1` runs the app with compact mode off, to get a
baseline of the page's untouched layout to compare against.

The CSS targets selectors read off the **live authenticated DOM** rather than guesses -
`WebChrome.probeJS` / `backgroundProbeJS` dump the page's landmarks and computed
backgrounds to the log when the app runs with `CLAUDE_COMPANION_PROBE=1`. That probe
showed only `body` (`rgb(21,21,21)`) and `main.dframe-content` paint an opaque backdrop;
every wrapper between them is already transparent.

Because claude.ai can change its markup at any time, `WebChrome.verifyJS` re-reads the
computed styles after each load and logs the result, so a silently-failed injection
shows up as a log line instead of a mysteriously opaque window:

```
style check: style injected=true body bg=rgba(0, 0, 0, 0) main bg=rgba(0, 0, 0, 0) \
    sidebar display=none large-opaque-elements=0
```

`large-opaque-elements` counts anything still painting over 20% of the viewport, which
is the single most useful signal that translucency has broken. It earned its keep
immediately: it caught the injection failing completely when a CSS *comment* containing
backticks terminated the JavaScript template literal the stylesheet was interpolated
into. The CSS is now passed through `jsStringLiteral` (JSON-encoded) so no CSS content
can break the injection script.

### Window position

The window rests **horizontally centred on the screen, 20pt above the Dock** - the spot
macOS companion utilities like Wispr Flow use: close to hand, without covering what
you're reading.

The window you're working in decides *which display* it appears on, so it follows you
across monitors - but not where on that display. Placement is the same screen-centred
spot regardless, which is what makes it predictable rather than jumping around with
whatever window happens to be focused.

How the active window is found (`ActiveWindow.swift`):

- `CGWindowListCopyWindowInfo` reports window geometry and owning process **without
  needing the Accessibility or Screen Recording permission** - only window *titles*
  and *images* are gated by those. The `AXUIElement` API would work too but costs the
  user a permission prompt.
- The frontmost app is tracked continuously via
  `NSWorkspace.didActivateApplicationNotification`, because showing the panel
  activates *us* - by the time the hot key fires, the app the user was working in is
  no longer frontmost.
- Windows belonging to full-screen apps on **other Spaces** are reported at parked
  coordinates outside the real display arrangement (several unrelated apps share one
  bogus origin), so any window that doesn't land on a real `NSScreen` is skipped.
- Core Graphics window bounds are y-down from the primary display's top-left; Cocoa
  is y-up from its bottom-left, so bounds are converted before use.
- The result uses the target screen's `visibleFrame`, so the window is always fully
  visible and above the Dock.

Fallbacks, in order: active window's screen → screen under the pointer → `NSScreen.main`.

Turn this off with **Follow Active Window** in the menu, and the window instead
reappears wherever you last dragged it (remembered across relaunches, and ignored if
that spot belongs to a monitor you've since unplugged). **Reset Position** clears it.

### Hot key handling

A combo can only be owned by one process at a time - `RegisterEventHotKey` returns
`eventHotKeyExistsErr` (-9878) to the loser. The ChatGPT desktop app claims
**⌥Space**, so the app tries a chain of combos and keeps the first one macOS grants:

⌥Space → ⌘⌥Space → ⌃⌥Space → ⌥C → ⌘⌥C

Whichever it got is shown in the menu-bar menu, and logged at startup.

## Troubleshooting

Check the log first - startup, hot key registration, navigation, and show/hide are
all recorded:

```bash
tail -20 ~/Library/Logs/ClaudeCompanion.log
```

If the shortcut does nothing, the menu-bar menu will tell you which combo is live
(another app may have taken ⌥Space). `./toggle.sh` always works regardless.

## Known limitations (v0.1 POC)

- **Passkeys do not work**, and cannot be made to. WKWebView exposes
  `window.PublicKeyCredential` but never vends the system authenticator to a
  third-party app: the platform-authenticator check returns false even with Touch
  ID enrolled and iCloud Keychain on. The entitlements that would unlock it
  (`com.apple.developer.associated-domains`, `com.apple.developer.web-browser`)
  are restricted - an ad-hoc signed build carrying either is killed by AMFI at
  launch. So the app deletes `PublicKeyCredential` outright at document start,
  which makes sign-in fall back to a method that does work rather than offering a
  passkey button that dead-ends.
- **Google "Sign in with Google"** can be blocked inside embedded web views by
  Google's security checks. Email / magic-link login works reliably.
- Hot key list and window width are fixed (no settings UI yet).
- The injected CSS depends on claude.ai's markup (`[data-testid="sidebar"]`,
  `[data-testid="chat-input"]`, `main.dframe-content`). If Anthropic renames those,
  the sidebar reappears or compact mode stops working - the `style check` log line is
  how you'd spot it.

## Bugs found and fixed during the first POC

- **Crash when a URL launched the app.** `open "claudecompanion://toggle"` (or
  `./toggle.sh`) with the app not running delivers the URL *before*
  `applicationDidFinishLaunching`, when the panel doesn't exist yet, and the handler
  crashed on it. URLs that arrive early are now held and run once launch finishes.
- **Silent startup failure.** Setting both `.canJoinAllSpaces` and
  `.moveToActiveSpace` on `collectionBehavior` is invalid (mutually exclusive) and
  raised an ObjC exception that AppKit swallowed. It aborted panel construction
  *and* hot key registration, so ⌥Space did nothing. Fixed, plus
  `NSSetUncaughtExceptionHandler` so this class of failure is never invisible again.
- **Ignored `OSStatus`.** Hot key registration failures were discarded. Now checked,
  logged, and recovered from via the fallback chain.
- **Private-API KVC hack.** `setValue(false, forKey: "drawsBackground")` on
  `WKWebView` has no such setter; replaced with the public `underPageBackgroundColor`.

## Licence

MIT - see [LICENSE](LICENSE).

Not affiliated with Anthropic. This is a third-party client that displays claude.ai in
a web view; you sign in with your own account.
