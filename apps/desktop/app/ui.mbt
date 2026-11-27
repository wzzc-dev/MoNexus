///|
/// Shell metrics and shared widgets.
///
/// Every number here belongs to the fixed 1280x800 window contract: 8pt outer
/// margin, 8pt island gap, 224pt sidebar, 44pt top bar, 26pt status bar. Views
/// never re-derive these; they compose the helpers below so the eight pages
/// read as one product.

///|
let ui_window_width : Double = 1280.0

///|
let ui_window_height : Double = 800.0

///|
let ui_margin : Double = 8.0

///|
let ui_gap : Double = 8.0

///|
let ui_island_radius : Double = 10.0

///|
let ui_sidebar_width : Double = 224.0

///|
let ui_sidebar_height : Double = 784.0

///|
let ui_main_width : Double = 1032.0

///|
let ui_main_height : Double = 784.0

///|
let ui_topbar_height : Double = 44.0

///|
let ui_statusbar_height : Double = 26.0

///|
let ui_body_padding : Double = 20.0

///|
let ui_body_width : Double = 992.0

///|
let ui_scroll_height : Double = 712.0

///|
/// One-pixel hairline border helper.
fn ui_edge(color : @core.Color) -> @core.BorderStyle {
  ui_border_style(color, 1.0)
}

///|
/// Island card: surface fill, hairline edge, shared radius.
fn ui_panel(
  child : @moui.View[Msg],
  width? : Double,
  height? : Double,
) -> @moui.View[Msg] {
  @views.container(
    child,
    width?,
    height?,
    background=ui_surface(),
    corner_radius=ui_island_radius,
    border=Some(ui_edge(ui_border())),
    padding=0.0,
  )
}

///|
/// Content card inside a page: surface fill, softer edge, 10pt radius.
fn ui_card(
  children : Array[@moui.View[Msg]],
  padding? : Double = 16.0,
  width? : Double,
) -> @moui.View[Msg] {
  // Pin the inner column to the card's content width: ContainerBox centres its
  // child, so an unpinned column would drift to the middle of wide cards.
  let inner = match width {
    Some(w) => @views.column(children, spacing=10.0).frame(
      width=(w - 2.0 * padding).max(0.0),
    )
    None => @views.column(children, spacing=10.0)
  }
  @views.container(
    @views.padding(inner, padding),
    width?,
    background=ui_surface(),
    corner_radius=10.0,
    border=Some(ui_edge(ui_border_soft())),
    padding=0.0,
  )
}

///|
/// Section label: 11pt semibold muted. Sits above a list or inside a card head.
fn ui_section(value : String) -> @moui.View[Msg] {
  @views.text(value, align=@core.TextAlign::TextStart)
  .font(ui_font(11.0, 600))
  .foreground(ui_muted())
}

///|
/// Small field label, 11pt muted.
fn ui_field_label(value : String) -> @moui.View[Msg] {
  @views.text(value, align=@core.TextAlign::TextStart).font(ui_font(11.0, 400)).foreground(ui_muted())
}

///|
/// Muted supporting copy.
fn ui_meta(value : String) -> @moui.View[Msg] {
  @views.text(value, align=@core.TextAlign::TextStart).font(ui_font(11.0, 400)).foreground(ui_muted())
}

///|
fn ui_muted_wrapped(
  value : String,
  width : Double,
) -> @moui.View[Msg] {
  @views.text(
    value,
    width=width,
    align=@core.TextAlign::TextStart,
    wrap=true,
  ).font(ui_font(12.0, 400)).foreground(ui_muted())
}

///|
/// List / card row title.
fn ui_row_title(value : String) -> @moui.View[Msg] {
  @views.text(value, align=@core.TextAlign::TextStart)
  .font(ui_font(14.0, 600))
  .foreground(ui_text_color())
}

///|
/// Wrapping row title pinned to a width so long names never push the row's
/// trailing actions off the island.
fn ui_row_title_wrapped(
  value : String,
  width : Double,
) -> @moui.View[Msg] {
  @views.text(
    value,
    width=width,
    align=@core.TextAlign::TextStart,
    wrap=true,
  ).font(ui_font(14.0, 600)).foreground(ui_text_color())
}

///|
/// Page title in the top bar.
fn ui_page_title(value : String) -> @moui.View[Msg] {
  @views.text(value, align=@core.TextAlign::TextStart).font(ui_font(15.0, 600)).foreground(ui_text_color())
}

///|
/// Home hero.
fn ui_hero(value : String) -> @moui.View[Msg] {
  @views.text(value, align=@core.TextAlign::TextStart).font(ui_font(22.0, 600)).foreground(ui_text_color())
}

///|
/// Monospace id/meta text. Ids never compete with the row title.
fn ui_mono(value : String, size : Double) -> @moui.View[Msg] {
  @views.text(value, align=@core.TextAlign::TextStart)
  .font(mono_font(size, 400))
  .foreground(ui_dim())
}

///|
fn ui_mono_wrapped(
  value : String,
  size : Double,
  width : Double,
  color : @core.Color,
) -> @moui.View[Msg] {
  @views.text(
    value,
    width=width,
    align=@core.TextAlign::TextStart,
    wrap=true,
  ).font(mono_font(size, 400)).foreground(color)
}

///|
/// A code / transcript well: code background, radius 8, mono body.
fn ui_code_block(
  value : String,
  width : Double,
  height? : Double,
  size? : Double,
) -> @moui.View[Msg] {
  let inner_width = (width - 24.0).max(0.0)
  let line = @views.text(
    value.trim_end().to_owned(),
    width=inner_width,
    align=@core.TextAlign::TextStart,
    wrap=true,
  ).font(mono_font_lh(size.unwrap_or(12.0), 400, size.unwrap_or(12.0) * 1.5))
  .foreground(ui_muted())
  // A fixed-height well must top-align its content; ContainerBox would
  // otherwise centre a single line in the middle of the empty box.
  let body = match height {
    Some(h) => @views.column([line], spacing=0.0).frame(
      width=inner_width,
      height=(h - 24.0).max(0.0),
    )
    None => line
  }
  @views.container(
    @views.padding(body, 12.0),
    width~,
    height?,
    background=ui_code_bg(),
    corner_radius=8.0,
    border=Some(ui_edge(ui_border_soft())),
    padding=0.0,
  )
}

///|
fn ui_divider() -> @moui.View[Msg] {
  @views.divider(color=ui_border(), thickness=1.0, inset=0.0)
}

///|
fn ui_divider_soft() -> @moui.View[Msg] {
  @views.divider(color=ui_border_soft(), thickness=1.0, inset=0.0)
}

///|
/// Six-pixel status dot.
fn ui_dot(color : @core.Color) -> @moui.View[Msg] {
  @views.container(
    @views.empty(),
    width=6.0,
    height=6.0,
    background=color,
    corner_radius=3.0,
    padding=0.0,
  )
}

///|
/// Outlined status tag sized to its label, so `waiting_approval` never clips.
fn ui_tag(label : String) -> @moui.View[Msg] {
  let tone = status_tone(label)
  @views.container(
    @views.padding_xy(
      @views.text(label, align=@core.TextAlign::TextStart).font(ui_font(11.0, 500)).foreground(tone),
      horizontal=8.0,
    ),
    height=22.0,
    corner_radius=11.0,
    border=Some(ui_edge(tone.multiply_alpha(0.5))),
    padding=0.0,
  )
}

///|
/// Neutral pill for counts and metadata that should not read as a status.
fn ui_pill(label : String, active : Bool) -> @moui.View[Msg] {
  @views.container(
    @views.padding_xy(
      @views.text(label, align=@core.TextAlign::TextStart).font(mono_font(10.0, 400)).foreground(
        if active {
          ui_accent()
        } else {
          ui_dim()
        },
      ),
      horizontal=6.0,
    ),
    height=18.0,
    background=if active { ui_accent_soft() } else { ui_surface_alt() },
    corner_radius=9.0,
    padding=0.0,
  )
}

///|
/// Host-state capsule: dot + label, hairline edge, 22pt tall.
fn ui_state_pill(label : String, tone : @core.Color) -> @moui.View[Msg] {
  @views.container(
    @views.padding_xy(
      @views.row([
        ui_dot(tone),
        @views.text(label, align=@core.TextAlign::TextStart).font(ui_font(11.0, 500)).foreground(ui_muted()),
      ], spacing=6.0, align=@style.CrossAlign::Center),
      horizontal=9.0,
      vertical=0.0,
    ),
    height=22.0,
    corner_radius=11.0,
    border=Some(ui_edge(ui_border())),
    padding=0.0,
  )
}

///|
/// Key/value row for the Home connection card and Settings spec sheet.
fn ui_kv(
  key : String,
  value : String,
  width : Double,
) -> @moui.View[Msg] {
  @views.row([
    @views.text(key, width=140.0, align=@core.TextAlign::TextStart).font(
      ui_font(11.0, 400),
    ).foreground(ui_muted()),
    @views.text(value, width=(width - 150.0).max(0.0), align=@core.TextAlign::TextStart, wrap=true)
    .font(mono_font(11.0, 400))
    .foreground(ui_dim()),
  ], spacing=10.0, align=@style.CrossAlign::Center)
}

///|
/// Home stat tile: label, big number, quiet footnote.
fn ui_stat_card(
  label : String,
  value : String,
  note : String,
  width : Double,
) -> @moui.View[Msg] {
  ui_card(
    [
      @views.text(label, align=@core.TextAlign::TextStart).font(ui_font(11.0, 600)).foreground(ui_muted()),
      @views.text(value, align=@core.TextAlign::TextStart).font(ui_font(24.0, 600)).foreground(ui_text_color()),
      @views.text(note, align=@core.TextAlign::TextStart).font(ui_font(11.0, 400)).foreground(ui_dim()),
    ],
    padding=16.0,
    width~,
  )
}

///|
/// Filled primary action in the one accent.
fn ui_primary(label : String, msg : Msg) -> @moui.View[Msg] {
  @views.button(
    label,
    on_click=msg,
    style=primary_button_style(ui_accent()),
    height=30.0,
  )
}

///|
/// Ghost action: transparent with hairline edge.
fn ui_ghost(label : String, msg : Msg) -> @moui.View[Msg] {
  @views.button(
    label,
    on_click=msg,
    style=ghost_button_style(),
    height=30.0,
  )
}

///|
/// Compact ghost action for the 44pt top bar.
fn ui_ghost_compact(label : String, msg : Msg, width : Double) -> @moui.View[Msg] {
  @views.button(
    label,
    on_click=msg,
    style=ghost_button_style(),
    width~,
    height=28.0,
  )
}

///|
fn ui_danger_ghost(label : String, msg : Msg) -> @moui.View[Msg] {
  @views.button(
    label,
    on_click=msg,
    style=danger_button_style(),
    height=30.0,
  )
}

///|
/// Small caption action (artifact reads, answer options) that still reads as a
/// control: ghost, 28pt tall.
fn ui_ghost_small(label : String, msg : Msg) -> @moui.View[Msg] {
  @views.button(
    label,
    on_click=msg,
    style=ghost_button_style(),
    height=28.0,
  )
}

///|
/// Labelled single-line input. The label sits above a 32pt filled field.
fn ui_field(
  label : String,
  value : String,
  on_input : (String) -> Msg,
  placeholder : String,
  width : Double,
) -> @moui.View[Msg] {
  @views.column([
    ui_field_label(label),
    @views.text_field(
      value,
      on_input=on_input,
      placeholder=placeholder,
      style=ui_field_style(),
      width~,
      height=32.0,
    ),
  ], spacing=5.0, align=@style.CrossAlign::Start)
}

///|
/// Labelled multi-line input, full theme-derived fill.
fn ui_text_area_field(
  label : String,
  value : String,
  on_input : (String) -> Msg,
  placeholder : String,
  width : Double,
  lines : Int32,
) -> @moui.View[Msg] {
  @views.column([
    ui_field_label(label),
    @views.text_area(
      value,
      on_input=on_input,
      placeholder=placeholder,
      lines~,
      variant=@style.TextFieldVariant::Filled,
      theme=field_theme(),
      width~,
      line_height=20.0,
    ),
  ], spacing=5.0, align=@style.CrossAlign::Start)
}

///|
/// Human-name selector backed by host projections. The selected value is the
/// stable id, but the visible label is always the projection's display name.
fn ui_select_field(
  label : String,
  items : Array[@views.MenuItem[Msg]],
  selected : String,
  expanded : Bool,
  on_toggle : Msg,
  placeholder : String,
  width : Double,
) -> @moui.View[Msg] {
  let state = @views.DropdownState::new(expanded~, selected~)
  @views.dropdown(
    label,
    items,
    state~,
    on_toggle=on_toggle,
    placeholder~,
    theme=app_theme(),
    width~,
    max_height=180.0,
  )
}

///|
/// Explicit disclosure for raw-id fallback fields. The normal path stays on
/// human names; operators who need an unprojected id can reveal it here.
fn ui_advanced_control(lang : Lang, open : Bool, msg : Msg) -> @moui.View[Msg] {
  ui_choice_segment(tr(lang, "Advanced", "高级"), open, msg)
}

///|
/// Secondary id row: muted mono text plus a copy affordance. Ids are never the
/// primary control in a form.
fn ui_id_meta(lang : Lang, label : String, id : String) -> @moui.View[Msg] {
  let shown = if id == "" {
    tr(lang, "(local / default)", "（本地 / 默认）")
  } else {
    id
  }
  let children : Array[@moui.View[Msg]] = [
    ui_field_label(label),
    ui_mono_wrapped(shown, 11.0, 520.0, ui_dim()),
  ]
  if id != "" {
    children.push(
      ui_ghost_small(tr(lang, "Copy", "复制"), CopyId(label, id)),
    )
  }
  @views.row(children, spacing=8.0, align=@style.CrossAlign::Center)
}

///|
/// One segment of a two-way Settings control. The active option is
/// accent-tinted; the other option is a quiet outline.
fn ui_choice_segment(
  label : String,
  active : Bool,
  msg : Msg,
) -> @moui.View[Msg] {
  let view = @views.container(
    @views.padding_xy(
      @views.text(label, align=@core.TextAlign::TextStart).font(ui_font(12.0, 500)).foreground(
        if active {
          ui_accent()
        } else {
          ui_muted()
        },
      ),
      horizontal=18.0,
    ),
    height=30.0,
    background=if active { ui_accent_soft() } else { ui_surface() },
    corner_radius=7.0,
    border=Some(
      ui_edge(
        if active {
          ui_accent().multiply_alpha(0.55)
        } else {
          ui_border()
        },
      ),
    ),
    padding=0.0,
  )
  view.on_tap(msg).cursor(
    @core.CursorStyle::Icon(@core.CursorIcon::CursorPointer),
  )
}

///|
fn ui_segment(
  label : String,
  mode : ThemeMode,
  current : ThemeMode,
) -> @moui.View[Msg] {
  ui_choice_segment(label, mode == current, SetTheme(mode))
}

///|
fn ui_language_segment(
  label : String,
  lang : Lang,
  current : Lang,
) -> @moui.View[Msg] {
  ui_choice_segment(label, lang == current, SetLanguage(lang))
}
