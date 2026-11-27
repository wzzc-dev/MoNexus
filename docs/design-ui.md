# Desktop visual system

The MoNexus desktop window is a fixed 1280×800 workbench: a near-black frame
holding two glowing islands, one dark-teal accent, and quiet semantic status
colours. Dark is the product default; the Settings page can flip the whole
window to a warm-paper light mode at runtime.

All values live in `apps/desktop/app/theme.mbt` (colour, type, controls) and
`apps/desktop/app/ui.mbt` (metrics, shared widgets). `apps/desktop/app/view.mbt`
composes pages from those helpers and never names a hex value.

## References

The shell borrows structure, not code, from three sibling MoonBit apps:

| Reference | What was borrowed |
| --- | --- |
| `~/Code/orca-moui/app/theme.mbt` | Near-black frame with lighter surfaces, hairline borders, Inter typography stack, restrained status palette, mono for ids and endpoints. |
| `~/Code/MoSpace/app/theme.mbt` | `palette_for(mode)` resolution, seeding MoUI's `ColorPalette` from the app palette, quiet ghost controls, accent-tinted active rail/style, brand mark, count pill, section label. |
| `~/Code/MoMark/app/ui_tokens.mbt` | Island metrics and the 8pt spacing rhythm (outer margin, island gap, bar heights). |

MoUI itself (`.mooncakes/wzzc-dev/moui`) is used as shipped: TEA `Program`,
`views` containers/rows/columns, `theme`, buttons, fields and the vendored
Lucide subset. No MoUI source is modified.

## Palette

One `Palette` is resolved per mode; every `ui_*` accessor reads it. `surface`
is the island fill, `frame` is the window behind the islands, `code_bg` is the
transcript/command well.

| Token | Dark | Light | Use |
| --- | --- | --- | --- |
| `frame` | `#0B0B0B` | `#EDEAE2` | Window background behind the islands |
| `surface` | `#161616` | `#FFFFFF` | Islands, cards, inputs at rest |
| `surface_alt` | `#1E1E1E` | `#F7F4EE` | Field fills, pressed ghost buttons |
| `hover` | `#222222` | `#F1EDE5` | Nav/row/button hover wash |
| `text` | `#EDEAE3` | `#23211D` | Titles and primary copy |
| `muted` | `#A39C91` | `#787167` | Labels, supporting copy, ghost controls |
| `dim` | `#6E6A63` | `#9C9487` | Mono ids, placeholders, footnotes |
| `border` | `rgba(255,255,255,0.08)` | `#E1DBD1` | Island/control hairline |
| `border_soft` | `rgba(255,255,255,0.05)` | `#ECE7DE` | Card edge, in-card divider |
| `accent` | `#6FBBA5` | `#2D6A5A` | Active nav, primary action, focus, links |
| `accent_soft` | 20% accent over surface (`≈#283733`) | 12% accent over white (`#E6EDEB`) | Selected rows, active nav/segment |
| `on_accent` | `#0B0B0B` | `#FFFFFF` | Text on an accent fill |
| `success` | `#57C08C` | `#2E7D5B` | succeeded / online / verified |
| `warning` | `#E3B341` | `#A66A12` | waiting states, needs you |
| `danger` | `#E68072` | `#B04A3E` | failed / denied / offline |
| `info` | `#60A5FA` | `#2B66D2` | running / queued |
| `code_bg` | `#121212` | `#FAF8F2` | Transcript, command and answer wells |

Startup appearance precedence, highest first:

1. the explicit choice saved from the Settings page;
2. a legal `MONEXUS_THEME=light|dark`;
3. dark, the product default.

The saved choice lives outside the workspace and the host event log, in one
small JSON file under the user's config directory:

- `$MONEXUS_CONFIG_DIR/theme.json` when that variable is set;
- else `$XDG_CONFIG_HOME/monexus/theme.json`;
- else `$HOME/.config/monexus/theme.json`;
- else `.config/monexus/theme.json`.

The file is `{"schema_version":1,"theme":"light"|"dark"}` and is written
atomically (temporary file plus rename) with mode 0600; it contains no secrets.
A missing file is silent. An unreadable, corrupt or unknown-valued file is
ignored, falls through to the next precedence rule and is reported as a
diagnostic on the Settings page; reading never rewrites it.

Language uses the same directory and rules: the saved choice
(`language.json`, `{"schema_version":1,"language":"en"|"zh"}`) wins, then a
legal `MONEXUS_LANG=en|zh`, then English. The file is also 0600 and atomic,
and a bad value is reported on Settings instead of changing the UI.
`theme_config_dir()` resolves the shared directory once for both preferences.

### Language switching

Every visible shell string is chosen at paint time through `tr(lang, en, zh)`
in `i18n.mbt`; ids, commands and host/agent diagnostics are not translated.
Page labels have a stable English form (`Page::label()`, used by scene
selection and tests) and a localized form (`Page::label_in(lang)`). The
Settings English/中文 segments dispatch `SetLanguage(lang)`; the model update
is pure and the explicit choice is queued to the preference worker, which
atomically rewrites `language.json` (0600). A fresh launch seeds `Model` from
`startup_language()` before the first frame.

The UI family stack adds PingFang SC, Hiragino Sans GB and Noto Sans CJK SC
after Inter so Chinese text has a CJK fallback on macOS and Linux; the mono
stack uses the same fallback after DejaVu Sans Mono. Host-returned messages are
shown verbatim, even in Chinese mode.

### Status tone mapping

Status is text and a hairline edge in its tone, never a filled badge:

| Statuses | Tone |
| --- | --- |
| `running`, `verifying`, `queued`, `starting` | info |
| `waiting_approval`, `waiting_owner`, `waiting_input`, `waiting_decision`, `needs_you`, `degraded` | warning |
| `succeeded`, `verified`, `answered`, `online`, `ready` | success |
| `failed`, `policy_denied`, `denied`, `offline`, `lost`, `expired` | danger |
| `draft`, `pending`, anything unknown | muted |

## Typography

| Role | Face | Size / weight |
| --- | --- | --- |
| Hero (Home) | Inter → System UI → Sans Serif | 22 / 600 |
| Page title | Inter | 15 / 600 |
| Row/card title | Inter | 14 / 600 |
| Body | Inter | 13 / 400 |
| Control | Inter | 13 / 500 |
| Caption / meta | Inter | 11 / 400 |
| Section label | Inter | 11 / 600 muted |
| Mono id / transcript | DejaVu Sans Mono → Monospace | 10–12 (ids 10.5) |
| Brand “M” | Serif | 15 / 600 |

MoUI's theme typography scale is seeded with the same values so built-in
controls (buttons, fields, checkbox) match the hand-painted shell.

## Shell metrics

The window is fixed at 1280×800; nothing horizontally scrolls or clips.

| Metric | Value |
| --- | --- |
| Outer margin | 8 |
| Island gap | 8 |
| Sidebar island | 224×784 |
| Main island | 1032×784 |
| Island radius / border | 10 / 1px |
| Top bar | 1032×44 |
| Scroll region | 1032×712 |
| Body padding | 20 (content width 992) |
| Status bar | 1032×26 |

### Sidebar

- Brand row: 44 tall, inset 14; 24×24 accent rounded square (radius 7) with a
  serif “M”, 9 gap, “MoNexus” 15/600.
- Nav block: inset 10 left/right, 8 top; rows 32 tall with 2 gap.
- Nav row: radius 7, horizontal inset 10, Lucide 16 + 10 gap + 13pt label.
  Active = `accent_soft` fill, accent icon/label (600 weight). Hover =
  `hover` fill, `text` tone. Inbox carries a 18-tall mono count pill when
  needs-you decisions exist.
- Home / Machines / Projects / Agents / Inbox / Tasks / Search, then a spacer,
  a soft divider, Settings pinned above the bottom, and a mono `0.1.0` footer.

### Top bar and status bar

- Top bar: page title at left; host capsule (6px dot + `host online`, 22 tall,
  hairline edge) and, on data pages, a 64×28 `Refresh` ghost at the right,
  spaced 10 apart. Horizontal padding 20.
- Status bar: mono 10.5, horizontal padding 20. Host id at left (or
  `not connected`); right shows `events: N · seq N` once events exist, else
  `MoNexus 0.1.0 · 8 pages`.

## Components

| Component | Spec |
| --- | --- |
| Primary action | Accent fill, `on_accent` label, 30 tall, radius 7, 13/500; hover lightens 8%, press darkens 8%. |
| Destructive action | Danger ghost: transparent, danger label and 45%-alpha danger edge, 30 tall. Used by Remove/Cancel. The primary style accepts a tone, so a filled danger action can reuse the same shape. |
| Ghost action | Transparent, `border` edge, `muted` label, hover `hover` fill + `text`; 30 tall (28 for compact top-bar and caption actions). |
| Input | Label 11 muted above a 32-tall field, 5 gap; `surface_alt` fill, 1px border, radius 7, 13pt text, accent edge on focus. Multi-line area uses the same fill, 3 lines, 20 line-height. |
| Card | `surface`, `border_soft`, radius 10, padding 16; list row-cards use 14 padding and selectable rows swap to `accent_soft` with a 45%-alpha accent edge. |
| Section label | 11/600 muted; list headers pair it with a right-aligned mono/11pt count. |
| Status tag | Content-width outlined capsule: height 22, radius 11, horizontal padding 8, 11/500 label, tone at 50% alpha for the edge. Width follows `waiting_approval` and never clips. |
| Count pill | Mono 10, height 18, radius 9; accent-soft/accent when the row is active. |
| Host capsule | 22 tall, dot 6 (radius 3), label 11/500, hairline edge. |
| Code / transcript well | `code_bg`, radius 8, `border_soft`, padding 12, mono 12 with 1.5 line-height, `muted`. Fixed-height wells top-align; trailing whitespace is trimmed so a one-line result stays visible. |
| Divider | 1px `border`; in-card separators use `border_soft`. |
| Icon | Vendored Lucide, 16px, tone from its row/tag. |

### Layout discipline

MoUI centres intrinsically sized children inside a `container`, and `text`
defaults to centred alignment. Every text helper therefore passes
`TextStart`, and any row that relies on `spacer(weight=1)` to push trailing
actions right is pinned to an explicit width (992 bars, 960/964/912 card rows).
Long titles and mono ids wrap inside fixed widths so controls never leave the
island.

## Pages

| Page | Content |
| --- | --- |
| Home | Hero “Welcome to MoNexus”, three 322-wide stat cards (Machines/Decisions/Tasks, 24/600 numbers), Connection card with state/host id/endpoint/version/events. |
| Machines | “Add machine” form card (name, host, user, port, identity) and saved-machine cards with Probe (ghost) and Remove (danger ghost). |
| Projects | Open-project form, open-workspaces list with Files/Editor/Git/Terminal/Worktree, and a project detail view with the same sections returned to by a back action. |
| Agents | Start-session form, transcript in a mono 12 `code_bg` well (“No session yet” when empty), follow-up input with Send, recent sessions list. |
| Inbox | Needs you / Waiting / Handled stat cards, Approvals summary card, then decision cards: tone dot, kind, status tags, title, meta, body, and answer options (Waive/Retry/Fail/Answer with text) plus the free-text answer card. |
| Tasks | Create card (Title, Workspace id, Goal, multi-line Verify commands), Board header with count, task row-cards with status tag and Select/Cancel, selected state, runs for the task, run detail (command well, evidence, artifacts, diff), Activity list. |
| Search | Query field and button, hits as cards, empty-state copy from the host search semantics. |
| Settings | Connection spec card (state/address/token/version/data dir/host id), Appearance card with a Light/Dark segmented control, Language card with an English/中文 segmented control, and a Local host note. |

## Appearance switching

`view` calls `apply_theme_mode(model.theme_mode)` before building the tree, so
the palette swap and the repaint happen on the same frame. The Settings
segments dispatch `SetTheme(mode)`; the model update stays pure (no reconnect,
no refetch) and the explicit choice is queued to the preference worker, which
atomically rewrites `theme.json` (0600) and reports a failed write back to the
Settings page. A fresh launch seeds `Model` from the saved choice through
`startup_theme()` before the first frame, so the window opens in the user's
mode. MoUI's theme is rebuilt from the active palette and seeded with
`ColorPalette::from_seed` (accent primary, `frame` background, `surface`,
`surface_alt`, `border` outline, semantic status colours, accent focus) with a
radius scale of 6/7/10/pill and control height 30.

## MoUI notes

- The vendored Lucide subset has no `monitor`, `bot`, `inbox`, `list-checks` or
  `folder-git-2`; pages map to the closest shipped glyph: Home `house`,
  Machines `server`, Projects `folder`, Agents `message-circle`, Inbox `mail`,
  Tasks `list`, Search `search`, Settings `settings`.
- MoUI 0.9.2 ships `segmented_control`, but the shell keeps its hand-painted
  pairs (`ui_choice_segment`, wrapped by `ui_segment` and
  `ui_language_segment`): two tappable containers whose active segment is
  accent-tinted, so the controls match the surrounding cards rather than
  importing another control style.
- No MoUI package changes were made for this redesign. Appearance and language
  persistence are desktop-local (`theme.json`/`language.json`, see above), not
  MoUI features.

## Verification

`moon build --target native`, `moon test --target native` (524/524) and
`scripts/acceptance.sh` (69 PASS / 0 FAIL) cover the build and M1–M7 behaviour;
the redesign touched only `apps/desktop` presentation. Review screenshots were
taken from a real host under Xvfb at 1360×900 with the window at 1280×800:
eight dark pages and four light pages (Home, Inbox, Tasks, Settings) under
`/tmp/monexus-ui-redesign/{dark,light}`. They are review artifacts, not
committed assets.
