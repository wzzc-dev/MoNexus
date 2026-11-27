# Desktop workroom visual system

The MoNexus desktop window is a fixed 1280×800 workroom. Two quiet islands sit
on a visible frame: a 224pt identity/sidebar island and a 1032pt main island.
The main island contains the Chat surface and, attached to its right edge by a
hairline, the Chat details rail. Chat is the product surface; Bot is identity;
Project, Workspace, Machine, Executor and AgentSession are context around the
current Chat.

Light is the product default. Dark mode remains a complete palette and the
Settings page can flip it at runtime. Theme and language choices persist
outside the workspace and outside the host event log.

All values live in `apps/desktop/app/theme.mbt` (colour and type),
`apps/desktop/app/ui.mbt` (metrics and shared widgets), and the view files
(`view.mbt`, `workroom_view.mbt`, `bot_detail_view.mbt`). Views compose from
these helpers and never name a hex value.

## References

The shell borrows structure, not code, from three sibling MoonBit apps:

| Reference | What was borrowed |
| --- | --- |
| `~/Code/orca-moui/app/theme.mbt` | Restrained status palette, hairline borders, Inter typography stack, mono ids and endpoints. |
| `~/Code/MoSpace/app/theme.mbt` | `palette_for(mode)` resolution, seeding MoUI's `ColorPalette`, quiet ghost controls, brand mark, section labels. |
| `~/Code/MoMark/app/ui_tokens.mbt` | Island metrics and the 8pt spacing rhythm (outer margin, island gap, bar heights). |

MoUI itself (`.mooncakes/wzzc-dev/moui`) is used as shipped: TEA `Program`,
`views` containers/rows/columns, `theme`, buttons, fields and the vendored
Lucide subset. No MoUI source is modified.

The interaction reference is the owner's workroom island mockup. Presentation
annotations from that file (audit lists, palette captions) are not part of the
app. The Bot page follows the owner's Bot ledger reference (screen 01); the
floating workspace (screen 02) is a separate follow-up and is not in this
shell.

## Palette

One `Palette` is resolved per mode; every `ui_*` accessor reads it. Tokens are
semantic: views choose `surface`, `paper`, `rail`, `line`, `ink`, `muted`, not
an arbitrary shade.

| Token | Dark | Light | Use |
| --- | --- | --- | --- |
| `frame` | `#0B0B09` | `#E7E2D7` | Window background behind and between islands |
| `paper` | `#181713` | `#FBFAF6` | Main island work surface |
| `rail` | `#1D1B16` | `#F1EEE6` | Sidebar island and details rail |
| `canvas` | `#181713` | `#FBFAF6` | Page canvas inside the main island |
| `surface` | `#211F1A` | `#FFFEFB` | Inputs, cards, quiet raised controls |
| `surface_alt` | `#24221C` | `#F7F4EE` | Field fills, transcript/user wash |
| `hover` | `#27251F` | `#F3F0E8` | Row hover wash |
| `selected` | `#2D2A23` | `#EAE5DB` | Active row / selected work item |
| `text` / `ink` | `#ECE7DC` | `#1D1F1B` | Titles, primary copy, ink buttons |
| `on_ink` | `#171610` | `#FFFEFB` | Text/glyph on an ink fill |
| `muted` | `#A39D91` | `#686D64` | Labels, supporting copy |
| `dim` | `#747066` | `#979B91` | Footnotes, secondary metadata |
| `line` (border) | `#37342C` | `#DDD8CD` | Island/control hairline |
| `line-soft` | `#2A2822` | `#E9E5DC` | In-card dividers |
| `moss` (success) | `#7FA184` | `#4B7356` | Online/succeeded/verified only |
| `amber` (warning) | `#C39A5B` | `#986B24` | Waiting, needs-you |
| `oxide` (danger) | `#C1786B` | `#9A473C` | Failed/denied/offline/destructive |
| `blue` (info/accent) | `#8099AA` | `#5A7183` | Running/queued/links |
| `code_bg` | `#14130F` | `#F7F4EE` | Transcript, command and answer wells |

Primary buttons use `ink`, never moss. Moss is reserved for status/success.
Danger actions use oxide. Secondary actions are transparent with a hairline.

Startup appearance precedence, highest first:

1. the explicit choice saved from Settings;
2. a legal `MONEXUS_THEME=light|dark`;
3. light, the product default.

The saved choice lives in one small JSON file under the user's config
directory:

- `$MONEXUS_CONFIG_DIR/theme.json` when set;
- else `$XDG_CONFIG_HOME/monexus/theme.json`;
- else `$HOME/.config/monexus/theme.json`;
- else `.config/monexus/theme.json`.

The file is `{"schema_version":1,"theme":"light"|"dark"}`, written atomically
(temporary file plus rename) with mode 0600. A missing file is silent. An
unreadable, corrupt or unknown-valued file is ignored, falls through to the
next precedence rule and is reported on Settings; reading never rewrites it.

Language follows the same directory and rules: saved `language.json`
(`{"schema_version":1,"language":"en"|"zh"}`, 0600) wins, then `MONEXUS_LANG`,
then English. Every visible shell string is selected at paint time through
`tr(lang, en, zh)`. Ids, commands and host/agent diagnostics are not
translated. `Page::label()` stays the stable English route identifier;
`Page::label_in(lang)` paints the localized label.

## Visual rules

- Flat surfaces, 1px hairlines, hierarchy through type weight, alignment and
  whitespace. No gradients, glow, glass, neon, floating dots or oversized
  shadows.
- No chat bubbles. A user entry is a paper wash with a 2px ink left rule;
  assistant replies are continuous transcript text. Work items and activity
  are inline rows.
- Bot icons are not repeated everywhere. One identity chip in the Chat header,
  one Bot row in the sidebar, and the Bot avatar on the Bot page are enough.
- No `Auto` badges, emoji decoration, uniform rounded-card grids, or raw ids
  as primary labels. Ids are copyable metadata in the details rail.
- Controls and list cards use 3–6px radii; islands use 10px. Spacing follows
  the 8pt rhythm. Type scale: 18/13/11/9 (the 21pt Bot name is the single
  identity exception).
- Icons are the existing vendored Lucide subset only, 14–16px and
  consistently toned.

## Typography

| Role | Face | Size / weight |
| --- | --- | --- |
| Workroom title | Inter | 18 / 650 |
| Bot identity name | Inter | 21 / 660 |
| Body / transcript | Inter | 13 / 400 |
| Row title | Inter | 11 / 500–620 |
| Control | Inter | 11–12 / 500 |
| Caption / meta | Inter | 9–10 / 400 |
| Section label | Inter | 8.5–9 / 600–650 muted |
| Mono id / metadata | DejaVu Sans Mono → Monospace | 8–10.5 |
| Brand “M” | Serif | 15 / 600 |

The family stacks add PingFang SC, Hiragino Sans GB and Noto Sans CJK SC after
Inter (and after DejaVu Sans Mono) so Chinese text has a native fallback on
macOS and Linux. Host-returned diagnostics are shown verbatim.

## Shell metrics

The window is fixed at 1280×800; nothing horizontally scrolls or clips.

| Metric | Value |
| --- | --- |
| Outer margin | 8 |
| Island gap | 8 |
| Sidebar island | 224×784 |
| Main island | 1032×784 |
| Island radius / border | 10 / 1px hairline |
| Top bar | 1032×44 |
| Main body | 1032×712 |
| Status bar | 1032×26 |
| Workroom split | 739 work column + 1px rule + 292 details rail |
| Details rail inner | 258 scroller, 17pt padding |
| Work header | 739×96 |
| Thread viewport | 739×444 |
| Composer | 739×172, 683 input width, 3 lines, 20 line-height |

### Left island order

1. Brand row (`MoNexus`, active Bot context).
2. `New Chat` action.
3. Chat list: active row with Chat title plus Bot name and recent activity;
   no raw ids. The current Agent session is the honest fallback Chat.
4. Bots: identity/status rows. The active Bot row opens its Bot page; selecting
   another Bot opens that Bot's latest known Chat, falling back to its Bot page
   when no Chat projection exists. The active row stays visible when it is
   older than the three most recent rows.
5. Secondary `工具` group: Inbox, Tasks, Manage, Search.
6. Host status and Settings at the bottom.

Chat, Bot, Inbox, Tasks, Manage, Search and Settings are the routes. There is
no top-level Agents page and no eighth primary Bot entry. `Manage` is one
destination with Projects and Machines tabs. Legacy labels map for deep links
and scene selection: Home/Chat/Chats → Workroom, Agents/Bot/Bots → Bot page,
Projects/Machines → Manage.

### Main island

- Top bar: breadcrumb (`对话 / <Bot> / <Chat>`, or `工具 / <page>`), compact
  search field, refresh where relevant, and secondary overflow actions (Inbox,
  Tasks, Manage, Settings). Breadcrumbs are clickable and preserve back
  behaviour.
- Workroom header: Chat title, status tag, Bot identity chip (opens Bot page),
  and project/workspace/updated as secondary meta.
- Thread: date divider, user entries, continuous assistant text, inline
  activity, and pending Decision rows with a link to Inbox. With no Chat or
  session, an honest empty state; no invented history.
- Composer: full-height 3-line text caret, Bot-name selector, project/workspace
  name selector, attach/tools, stop when a session exists, and an ink send
  button. The visible selector values are names, never ids.
- Status bar: host status at the left; event sequence or `MoNexus · workroom`
  at the right.

### Details rail

The rail is inside the main island and separated by a 1px vertical rule:

- status (current state, updated time);
- participants (Bot + Owner, Bot identity clickable);
- context (Project, Workspace, Machine, Executor/Agent, AgentSession);
- pending decisions (`待你处理`), limited to the current needs-you items;
- files/artifacts from the session, with an honest empty state;
- copyable ids as secondary metadata, with a footer note that they are not
  navigation.

Project and Machine context rows keep their existing actions reachable.

## Bot page

The Bot page is opened from a Bot row or the Bot identity chip. It is a Bot
identity/work ledger, not a new nav system and not a dashboard of rounded
cards.

- Identity header: 38px ink avatar, 21pt name, status tag, short context and
  Chat count. Actions: new Chat, plus `打开当前 Chat` only when a Chat is
  actually projected for this Bot.
- Quiet tabs under the header: `主页 / 聊天 / Agents / 文件` with counts where
  data exists; a shared-memory summary note is metadata only. No invented
  connector tab.
- 主页: work items grouped by `进行中 / Waiting / 已计划 / 已关闭` with counts;
  rows show `#ID` (mono, secondary), title, elapsed/updated time, and
  expand/collapse. `再显示 N 项` expands the list. Automations follow with
  cadence and a quiet hint, or one honest empty row.
- Selecting an item opens a right-side detail pane with a `主页` back link,
  title/status/item/chat/time metadata, 目标, 完成标准, 聊天 preview, activity
  timeline, and a comment composer with a character count. The composer is
  capped at 50 characters; until host comment persistence exists, saving is
  local to the window and says so.
- 聊天: Chat rows and an honest empty state. Agents: session start/manage
  actions live here. 文件: session artifacts only when the current Agent
  session belongs to this Bot; otherwise an honest empty state.
- Projects: Chat records carry a project id, not a workspace id, so the page
  does not join those id spaces. It shows an honest "no project projection"
  row with a Manage link until a typed Bot-to-project projection exists.

The same paper/ink/stone tokens and hairline/row system are used throughout.
The left work-item pane is 430pt and the right detail pane 601pt inside the
main island; both scroll independently.

## Secondary tools

| Destination | Content and preserved actions |
| --- | --- |
| Inbox | Needs you / Waiting / Handled counts and decision cards; answer, approve, retry, fail, waive and free-text actions remain. |
| Tasks | Create task, Board, task select/cancel, runs, evidence, artifacts, diff and activity. |
| Manage → Projects | Open project, workspace list, Files/Editor/Git/Terminal/Worktree actions, project detail with back. |
| Manage → Machines | Add/probe/remove machine, saved-machine cards, connection details. |
| Search | Session/transcript search and hit cards. |
| Settings | Connection, Appearance (Light/Dark), Language (English/中文), local-host note. |

`Manage` is one secondary route with a quiet segmented control. Projects and
Machines are not peer top-level pages.

## Components

| Component | Spec |
| --- | --- |
| Primary action | Ink fill, `on_ink` label, 30 tall, radius 4, 11–13/500; hover lightens 8%, press darkens 8%. Never moss. |
| Destructive action | Oxide ghost: transparent, oxide label, 45%-alpha oxide edge, 30 tall. |
| Ghost action | Transparent, `line` edge, `muted` label, hover `hover` fill + `text`; 30 tall (28 compact). |
| Input | 11pt muted label above a 32-tall field, 5 gap; `surface_alt` fill, 1px hairline, radius 4, 13pt text, blue edge on focus. Multi-line area keeps 3 lines and 20 line-height. |
| Card | `surface`, `line-soft` edge, radius 6, padding 16. No shadow. |
| Section label | 8.5–11/600 muted; list headers pair it with a right-aligned count. |
| Status tag | Content-width outlined capsule, 22 tall, radius 11, 10–11/500; tone used on text and a 50%-alpha edge, not a filled badge. |
| Host/status dot | 6px dot, radius 3; moss online, amber connecting, oxide offline. |
| Divider | 1px `line`; in-card separators use `line-soft`. |
| Icon | Vendored Lucide 14–16px, tone from its row/tag. |

MoUI centres intrinsically sized children inside a `container`, and text
defaults to centred alignment. Every text helper passes `TextStart`; rows that
use `spacer(weight=1)` are pinned to explicit widths (992 bars, 960/683/557
content widths). Scroll views are isolated so the workroom thread, details
rail, Bot item pane and Bot detail pane do not nest vertical scrollers.

### Status tone mapping

Status is text plus a hairline in its tone, never a filled badge.

| Statuses | Tone |
| --- | --- |
| `running`, `verifying`, `queued`, `starting` | blue/info |
| `waiting_approval`, `waiting_owner`, `waiting_input`, `waiting_decision`, `needs_you`, `degraded` | amber/warning |
| `succeeded`, `verified`, `answered`, `online`, `ready`, `active` | moss/success |
| `failed`, `policy_denied`, `denied`, `offline`, `lost`, `expired` | oxide/danger |
| `draft`, `pending`, `idle`, anything unknown | muted/dim |

## Data and architecture boundary

- This is a presentation-layer change. Host RPC, contracts, domain model,
  event log and persistence are unchanged.
- Existing Agent session, project, machine, workspace, Task and Inbox data
  powers the workroom. The current Agent session is the single active Chat
  when no Chat projection is loaded.
- `bot.list` and `chat.list` projections are typed seams (`BotsLoaded`,
  `ChatsLoaded`, `BotIdentity`, `ChatProjection`) but are not wired to a
  production adapter yet. Until P0.3/P1 data exists the UI shows an honest
  empty state and does not hardcode fake Chats, Bots, work items or activity.
- Task work items on the Bot page only appear when the existing Task record's
  agent binding matches the Bot/Agent identity; otherwise they stay out of
  that Bot's ledger.
- Every existing action remains reachable: session start/send/stop/resume,
  project open/files/editor/git/terminal/worktree, machine add/probe/remove,
  Task create/select/cancel/run, Inbox decisions, Search and Settings.
- Deep links/back behaviour stays stable through `Page::from_label` and the
  existing route labels. No new ADR is introduced for this redesign.

## Appearance switching

`view` calls `apply_theme_mode(model.theme_mode)` before building the tree, so
the palette swap and repaint happen on the same frame. Settings dispatches
`SetTheme(mode)`; the update is pure, and the explicit choice is queued to the
preference worker, which atomically rewrites `theme.json` (0600) and reports a
failed write back to Settings. A fresh launch seeds the model from the saved
choice before the first frame.

MoUI's theme is rebuilt from the active palette and seeded with
`ColorPalette::from_seed` (ink primary, `frame` background, `surface`,
`surface_alt`, `line` outline, semantic status colours, blue focus) with a
radius scale of 3/4/10/pill and control height 30.

## MoUI notes

- The vendored Lucide subset has no `monitor`, `bot`, `inbox`, `list-checks` or
  `folder-git-2`; routes map to the closest shipped glyph: Chat
  `message-circle`, Bot `users`, Inbox `mail`, Tasks `list`, Manage
  `columns-3`, Search `search`, Settings `settings`.
- MoUI ships `segmented_control`, but the shell keeps its hand-painted
  `ui_choice_segment` pairs so tabs and filters match the surrounding rows
  instead of importing another control style.
- No MoUI package changes were made for this redesign.

## Verification

The affected native build and test commands are:

```sh
bash -lc 'packages="$(bash scripts/native_packages.sh)"; moon build --target native $packages'
bash -lc 'packages="$(bash scripts/native_packages.sh)"; moon test --target native $packages'
bash scripts/acceptance.sh
git diff --check
```

Acceptance renders the real desktop scenes at 1280×800 in both modes for the
workroom, Inbox, Manage (Projects/Machines), Tasks and Settings, plus the Bot
page. The screenshots are review artifacts, not committed assets; the exact
path from the run is recorded in the PR evidence.
