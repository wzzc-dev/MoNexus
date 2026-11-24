///|
using @views {button, card, center, column, row, spacer, text}

///|
fn nav_button(page : Page, current : Page) -> @moui.View[Msg] {
  let label = page.label()
  let view = button(label, on_click=SelectPage(page))
  if page.label() == current.label() {
    view.title()
  } else {
    view
  }
}

///|
fn host_summary(host : HostProjection) -> @moui.View[Msg] {
  let lines : Array[@moui.View[Msg]] = [
    text("MoNexus host: " + host.link.label()),
    text(
      if host.host_id == "" {
        "host id: (not connected)"
      } else {
        "host id: " + host.host_id
      },
    ),
  ]
  if host.version != "" {
    lines.push(text("version: " + host.version))
  }
  if host.ws_url != "" {
    lines.push(text("endpoint: " + host.ws_url).caption())
  }
  if host.event_count > 0 {
    lines.push(
      text(
        "events: " +
        host.event_count.to_string() +
        " (last " +
        host.last_event +
        " @" +
        host.event_seq.to_string() +
        ")",
      ).caption(),
    )
  }
  if host.last_error != "" {
    lines.push(text("reason: " + host.last_error).caption())
  }
  column(lines, spacing=6.0)
}

///|
fn page_body(model : Model) -> @moui.View[Msg] {
  match model.page {
    Home =>
      column([
        text("Welcome to MoNexus").title(),
        text(
          "A local-first desktop shell for machines, tasks and agent sessions.",
        ),
        host_summary(model.host),
      ], spacing=10.0)
    Machines =>
      column([
        text("Machines").title(),
        text("Machines page"),
        text("M2 will list saved machines and run provider probes here."),
      ], spacing=10.0)
    Tasks =>
      column([
        text("Tasks").title(),
        text("Tasks page"),
        text("M3 will show task runs and their event streams here."),
      ], spacing=10.0)
    Search =>
      column([
        text("Search").title(),
        text("Search page"),
        text("M4 will wire ACP-backed search and results here."),
      ], spacing=10.0)
    Settings =>
      column([
        text("Settings").title(),
        text("Settings page"),
        text("state dir: " + model.host.state_dir).mono(),
        text("Token and endpoint come from host.json (mode 0600).").caption(),
      ], spacing=10.0)
  }
}

///|
pub fn view(model : Model) -> @moui.View[Msg] {
  let nav : Array[@moui.View[Msg]] = []
  for page in [Home, Machines, Tasks, Search, Settings] {
    nav.push(nav_button(page, model.page))
  }
  center(
    card(
      column([
        row([
          text("MoNexus").title(),
          spacer(weight=1.0),
          text("host " + model.host.link.label()),
        ], spacing=16.0),
        row(nav, spacing=8.0),
        card(page_body(model)),
      ], spacing=16.0),
      padding=20.0,
    ),
    width=920.0,
    height=560.0,
  )
}
