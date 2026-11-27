///|
/// MoNexus desktop visual system.
///
/// One resolved `Palette` carries every colour the shell paints; views read it
/// through the `ui_*` accessors so a mode flip repaints the whole window from
/// a single cell. Values follow Orca's dark workbench structure (near-black
/// frame, glowing panels, hairline borders) and MoSpace's warm-paper light
/// counterpart, with one dark-teal accent and restrained status colours.
///
/// Nothing outside this file names a hex value; `docs/design-ui.md` records the
/// same tables.

///|
/// Appearance mode. Dark is the product default; a saved Settings choice
/// decides the startup mode when present, and `MONEXUS_THEME` decides it
/// before any choice has been saved. The Settings page can flip it at runtime.
#derive(Eq)
pub(all) enum ThemeMode {
  Dark
  Light
}

///|
pub fn ThemeMode::label(self : ThemeMode) -> String {
  match self {
    Dark => "Dark"
    Light => "Light"
  }
}

///|
/// Stable lowercase form used by the preference file and by `MONEXUS_THEME`.
pub fn ThemeMode::pref_value(self : ThemeMode) -> String {
  match self {
    Dark => "dark"
    Light => "light"
  }
}

///|
/// Parse one appearance value. Only `light` and `dark` are legal, matched
/// case-insensitively; anything else returns `None` so callers can fall back
/// deterministically.
pub fn theme_mode_from_value(value : String) -> ThemeMode? {
  match value.to_lower() {
    "light" => Some(Light)
    "dark" => Some(Dark)
    _ => None
  }
}

///|
fn rgb8(r : Int32, g : Int32, b : Int32) -> @core.Color {
  @core.Color::rgba(
    r=r.to_double() / 255.0,
    g=g.to_double() / 255.0,
    b=b.to_double() / 255.0,
    a=1.0,
  )
}

///|
fn white_a(alpha : Double) -> @core.Color {
  @core.Color::rgba(r=1.0, g=1.0, b=1.0, a=alpha)
}

///|
/// One resolved token set. Semantic roles only: a widget never invents its own
/// shade, it picks `surface`, `hover`, `border`, `accent` and so on.
priv struct Palette {
  frame : @core.Color
  surface : @core.Color
  surface_alt : @core.Color
  hover : @core.Color
  text : @core.Color
  muted : @core.Color
  dim : @core.Color
  border : @core.Color
  border_soft : @core.Color
  accent : @core.Color
  accent_soft : @core.Color
  on_accent : @core.Color
  success : @core.Color
  warning : @core.Color
  danger : @core.Color
  info : @core.Color
  code_bg : @core.Color
  is_dark : Bool
}

///|
fn palette_for(mode : ThemeMode) -> Palette {
  match mode {
    Dark => {
      let surface = rgb8(22, 22, 22)
      let accent = rgb8(111, 187, 165)
      {
        frame: rgb8(11, 11, 11),
        surface,
        surface_alt: rgb8(30, 30, 30),
        hover: rgb8(34, 34, 34),
        text: rgb8(237, 234, 227),
        muted: rgb8(163, 156, 145),
        dim: rgb8(110, 106, 99),
        border: white_a(0.08),
        border_soft: white_a(0.05),
        accent,
        accent_soft: accent.mix(surface, 0.80),
        on_accent: rgb8(11, 11, 11),
        success: rgb8(87, 192, 140),
        warning: rgb8(227, 179, 65),
        danger: rgb8(230, 128, 114),
        info: rgb8(96, 165, 250),
        code_bg: rgb8(18, 18, 18),
        is_dark: true,
      }
    }
    Light => {
      let white = rgb8(255, 255, 255)
      let accent = rgb8(45, 106, 90)
      {
        frame: rgb8(237, 234, 226),
        surface: white,
        surface_alt: rgb8(247, 244, 238),
        hover: rgb8(241, 237, 229),
        text: rgb8(35, 33, 29),
        muted: rgb8(120, 113, 103),
        dim: rgb8(156, 148, 135),
        border: rgb8(225, 219, 209),
        border_soft: rgb8(236, 231, 222),
        accent,
        accent_soft: accent.mix(white, 0.88),
        on_accent: white,
        success: rgb8(46, 125, 91),
        warning: rgb8(166, 106, 18),
        danger: rgb8(176, 74, 62),
        info: rgb8(43, 102, 210),
        code_bg: rgb8(250, 248, 242),
        is_dark: false,
      }
    }
  }
}

///|
let palette_state : Ref[Palette] = Ref(palette_for(Dark))

///|
/// Swap the active palette. `view` calls this before building the tree, so the
/// whole shell (including MoUI's built-in controls, which read the theme below)
/// repaints in the new mode on the same frame.
pub fn apply_theme_mode(mode : ThemeMode) -> Unit {
  palette_state.val = palette_for(mode)
}

///|
fn ui_frame() -> @core.Color {
  palette_state.val.frame
}

///|
fn ui_surface() -> @core.Color {
  palette_state.val.surface
}

///|
fn ui_surface_alt() -> @core.Color {
  palette_state.val.surface_alt
}

///|
fn ui_hover() -> @core.Color {
  palette_state.val.hover
}

///|
fn ui_text_color() -> @core.Color {
  palette_state.val.text
}

///|
fn ui_muted() -> @core.Color {
  palette_state.val.muted
}

///|
fn ui_dim() -> @core.Color {
  palette_state.val.dim
}

///|
fn ui_border() -> @core.Color {
  palette_state.val.border
}

///|
fn ui_border_soft() -> @core.Color {
  palette_state.val.border_soft
}

///|
fn ui_accent() -> @core.Color {
  palette_state.val.accent
}

///|
fn ui_accent_soft() -> @core.Color {
  palette_state.val.accent_soft
}

///|
fn ui_on_accent() -> @core.Color {
  palette_state.val.on_accent
}

///|
fn ui_success() -> @core.Color {
  palette_state.val.success
}

///|
fn ui_warning() -> @core.Color {
  palette_state.val.warning
}

///|
fn ui_danger() -> @core.Color {
  palette_state.val.danger
}

///|
fn ui_info() -> @core.Color {
  palette_state.val.info
}

///|
fn ui_code_bg() -> @core.Color {
  palette_state.val.code_bg
}

///|
fn ui_family() -> @core.FontFamilyStack {
  @core.FontFamilyStack::new([
    @core.FontFamily::Name("Inter"),
    // CJK fallbacks for the Chinese UI. A missing family is skipped by the
    // renderer, so these do not change the English stack on machines without
    // them.
    @core.FontFamily::Name("PingFang SC"),
    @core.FontFamily::Name("Hiragino Sans GB"),
    @core.FontFamily::Name("Noto Sans CJK SC"),
    @core.FontFamily::Name("Noto Sans SC"),
    @core.FontFamily::SystemUi,
    @core.FontFamily::SansSerif,
  ])
}

///|
/// UI face: Inter with system fallbacks, the same stack Orca uses.
fn ui_font(size : Double, weight : Int32) -> @core.FontSpec {
  @core.FontSpec::new(families=ui_family(), size~, weight~)
}

///|
/// Mono face for task/run/host/workspace ids, endpoints and commands.
fn mono_font(size : Double, weight : Int32) -> @core.FontSpec {
  @core.FontSpec::new(
    families=@core.FontFamilyStack::new([
      @core.FontFamily::Name("DejaVu Sans Mono"),
      @core.FontFamily::Name("PingFang SC"),
      @core.FontFamily::Name("Noto Sans CJK SC"),
      @core.FontFamily::Monospace,
    ]),
    size~,
    weight~,
  )
}

///|
fn mono_font_lh(
  size : Double,
  weight : Int32,
  line_height : Double,
) -> @core.FontSpec {
  @core.FontSpec::new(
    families=@core.FontFamilyStack::new([
      @core.FontFamily::Name("DejaVu Sans Mono"),
      @core.FontFamily::Name("PingFang SC"),
      @core.FontFamily::Name("Noto Sans CJK SC"),
      @core.FontFamily::Monospace,
    ]),
    size~,
    weight~,
    line_height~,
  )
}

///|
fn serif_font(size : Double) -> @core.FontSpec {
  @core.FontSpec::new(
    families=@core.FontFamilyStack::serif(),
    size~,
    weight=600,
  )
}

///|
fn ui_typography() -> @core.TypographyScale {
  {
    display: ui_font(22.0, 600),
    headline: ui_font(15.0, 600),
    title: ui_font(14.0, 600),
    subtitle: ui_font(14.0, 500),
    body: ui_font(13.0, 400),
    label: ui_font(13.0, 500),
    caption: ui_font(11.0, 400),
    overline: ui_font(11.0, 600),
    control: ui_font(13.0, 500),
  }
}

///|
/// The MoUI theme: MoSpace-style seeding of the framework `ColorPalette` from
/// our tokens keeps buttons, fields, checkbox marks and focus rings on the same
/// accent and surfaces as the hand-painted shell.
fn app_theme() -> @core.Theme {
  let p = palette_state.val
  let scheme = if p.is_dark {
    @core.ColorScheme::Dark
  } else {
    @core.ColorScheme::Light
  }
  let base = if p.is_dark {
    @views.desktop_dark_theme()
  } else {
    @views.desktop_light_theme()
  }
  let seed = @core.ColorPalette::from_seed(
    primary=p.accent,
    scheme,
    foreground=p.text,
    background=p.frame,
    surface=p.surface,
    surface_variant=p.surface_alt,
    outline=p.border,
    muted=p.muted,
  )
  let palette = {
    ..seed,
    success: p.success,
    warning: p.warning,
    danger: p.danger,
    error: p.danger,
    info: p.info,
    focus: p.accent,
  }
  @views.theme(
    base~,
    scheme~,
    palette~,
    radius_scale=@core.RadiusScale::{
      sm: 6.0,
      md: 7.0,
      lg: 10.0,
      pill: 999.0,
    },
    layout_scale=@core.LayoutScale::{
      control_height: 30.0,
      control_padding_x: 12.0,
      row_height: 32.0,
      card_padding: 16.0,
      overlay_padding: 16.0,
      dialog_padding: 20.0,
    },
    typography=ui_typography(),
  )
}

///|
/// Theme variant for `text_area`, whose control colours come from the palette
/// rather than a per-call style: fill with `surface_alt` so inputs read as
/// inset wells inside a card.
fn field_theme() -> @core.Theme {
  let base = app_theme()
  let p = palette_state.val
  base.with_palette({
    ..base.palette,
    surface: p.surface_alt,
    surface_variant: p.surface_alt,
  })
}

///|
fn ui_border_style(color : @core.Color, width : Double) -> @core.BorderStyle {
  @core.BorderStyle::new(brush=@core.Brush::solid(color), width~)
}

///|
fn transparent_brush() -> @core.Brush {
  @core.Brush::solid(@core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0))
}

///|
/// Filled primary action: accent background, readable foreground, quiet hover
/// lift. `tone` lets destructive actions reuse the shape in danger red.
fn primary_button_style(tone : @core.Color) -> @views.ButtonStyle {
  let normal = @views.new_control_state_style(
    foreground=ui_on_accent(),
    background=@core.Brush::solid(tone),
    radius=7.0,
  )
  let hovered = @views.new_control_state_style(
    foreground=ui_on_accent(),
    background=@core.Brush::solid(tone.lighten(0.08)),
    radius=7.0,
  )
  let pressed = @views.new_control_state_style(
    foreground=ui_on_accent(),
    background=@core.Brush::solid(tone.darken(0.08)),
    radius=7.0,
  )
  let disabled = @views.new_control_state_style(
    foreground=ui_dim(),
    background=@core.Brush::solid(tone.mix(ui_surface(), 0.6)),
    radius=7.0,
  )
  @views.ButtonStyle::new(normal~, hovered~, pressed~, disabled~)
}

///|
/// Ghost action: transparent at rest with a hairline edge, hover wash. Used for
/// every secondary action so the shell never grows another default pill.
fn ghost_button_style() -> @views.ButtonStyle {
  let edge = @core.BorderStyle::new(
    brush=@core.Brush::solid(ui_border()),
    width=1.0,
  )
  let transparent = transparent_brush()
  let normal = @views.new_control_state_style(
    foreground=ui_muted(),
    background=transparent,
    border=edge,
    radius=7.0,
  )
  let hovered = @views.new_control_state_style(
    foreground=ui_text_color(),
    background=@core.Brush::solid(ui_hover()),
    border=edge,
    radius=7.0,
  )
  let pressed = @views.new_control_state_style(
    foreground=ui_text_color(),
    background=@core.Brush::solid(ui_surface_alt()),
    border=edge,
    radius=7.0,
  )
  let disabled = @views.new_control_state_style(
    foreground=ui_dim(),
    background=transparent,
    border=edge,
    radius=7.0,
  )
  @views.ButtonStyle::new(normal~, hovered~, pressed~, disabled~)
}

///|
/// Destructive ghost: same footprint, danger label and edge.
fn danger_button_style() -> @views.ButtonStyle {
  let edge = @core.BorderStyle::new(
    brush=@core.Brush::solid(ui_danger().multiply_alpha(0.45)),
    width=1.0,
  )
  let transparent = transparent_brush()
  let normal = @views.new_control_state_style(
    foreground=ui_danger(),
    background=transparent,
    border=edge,
    radius=7.0,
  )
  let hovered = @views.new_control_state_style(
    foreground=ui_danger(),
    background=@core.Brush::solid(ui_danger().multiply_alpha(0.10)),
    border=edge,
    radius=7.0,
  )
  let pressed = @views.new_control_state_style(
    foreground=ui_danger(),
    background=@core.Brush::solid(ui_danger().multiply_alpha(0.16)),
    border=edge,
    radius=7.0,
  )
  let disabled = @views.new_control_state_style(
    foreground=ui_dim(),
    background=transparent,
    border=edge,
    radius=7.0,
  )
  @views.ButtonStyle::new(normal~, hovered~, pressed~, disabled~)
}

///|
/// Text field: inset fill, hairline edge, accent focus edge.
fn ui_field_style() -> @style.TextFieldStyle {
  let normal = @views.new_control_state_style(
    foreground=ui_text_color(),
    background=@core.Brush::solid(ui_surface_alt()),
    border=@core.BorderStyle::new(
      brush=@core.Brush::solid(ui_border()),
      width=1.0,
    ),
    radius=7.0,
  )
  let focused = @views.new_control_state_style(
    foreground=ui_text_color(),
    background=@core.Brush::solid(ui_surface_alt()),
    border=@core.BorderStyle::new(
      brush=@core.Brush::solid(ui_accent()),
      width=1.0,
    ),
    radius=7.0,
  )
  let disabled = @views.new_control_state_style(
    foreground=ui_dim(),
    background=@core.Brush::solid(ui_surface()),
    border=@core.BorderStyle::new(
      brush=@core.Brush::solid(ui_border_soft()),
      width=1.0,
    ),
    radius=7.0,
  )
  @style.TextFieldStyle::new(
    normal~,
    focused~,
    disabled~,
    placeholder_color=ui_dim(),
    cursor_color=ui_accent(),
    font=ui_font(13.0, 400),
  )
}

///|
/// Status colour for a record state. Deliberately quiet: accent is the only
/// loud colour in the shell, statuses stay inside four semantic tones.
fn status_tone(status : String) -> @core.Color {
  match status {
    "running" | "verifying" | "queued" | "starting" =>
      ui_info()
    "waiting_approval" |
    "waiting_owner" |
    "waiting_input" |
    "waiting_decision" |
    "needs_you" |
    "degraded" |
    "interrupted" =>
      ui_warning()
    "succeeded" |
    "verified" |
    "answered" |
    "online" |
    "ready" =>
      ui_success()
    "failed" |
    "policy_denied" |
    "denied" |
    "offline" |
    "lost" |
    "expired" =>
      ui_danger()
    _ => ui_muted()
  }
}
