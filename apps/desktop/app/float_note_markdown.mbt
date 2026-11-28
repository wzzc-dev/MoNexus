///|
/// The floating note keeps canonical Markdown source in `.md` files while the
/// editor works from a long-lived Markdown document session. These helpers are
/// pure so source synchronization, formatting commands, source-mode switching,
/// and selection updates can be tested without mounting the UI.

///|
pub fn float_note_selection(
  note : FloatNote,
) -> @richtext.MarkdownEditorSelection {
  note.selection
}

///|
pub fn float_note_apply_edit(
  note : FloatNote,
  transaction : @richtext.MarkdownEditTransaction,
) -> FloatNote {
  if transaction.previous_source != note.content {
    return note
  }
  let selection : @richtext.MarkdownEditorSelection = {
    caret: transaction.caret,
    selection: transaction.selection,
  }
  if transaction.source == note.content {
    if selection == note.selection {
      return note
    }
    return { ..note, selection, }
  }
  let session = note.session.apply(transaction)
  let source = session.source()
  if source == note.content {
    return note
  }
  {
    ..note,
    content: source,
    session,
    selection,
    state: FloatNoteSaving,
    revision: note.revision + 1,
  }
}

///|
pub fn float_note_apply_command(
  note : FloatNote,
  command : @richtext.MarkdownEditorCommand,
) -> FloatNote {
  let result = @richtext.markdown_editor_apply_command_at(
    note.content,
    command,
    Some(note.selection),
  )
  if result.source == note.content &&
    result.caret == note.selection.caret &&
    result.selection == note.selection.selection {
    return note
  }
  let transaction = @richtext.MarkdownEditTransaction::from_edit_result(
    note.content,
    result,
    reason=@richtext.CommandEdit,
  )
  float_note_apply_edit(note, transaction)
}

///|
pub fn float_note_replace_content(
  note : FloatNote,
  content : String,
) -> FloatNote {
  if content == note.content {
    return note
  }
  let session = note.session.replace_source(
    content,
    reason=@richtext.ReplaceEdit,
  )
  let source = session.source()
  let caret = @richtext.markdown_editor_clamp_int(
    note.selection.caret,
    0,
    source.length(),
  )
  {
    ..note,
    content: source,
    session,
    selection: { caret, selection: None, },
    state: FloatNoteSaving,
    revision: note.revision + 1,
  }
}

///|
pub fn float_note_set_selection(
  note : FloatNote,
  caret : Int32,
  selection : @core.TextRange?,
) -> FloatNote {
  let next : @richtext.MarkdownEditorSelection = { caret, selection, }
  if next == note.selection {
    return note
  }
  { ..note, selection: next, }
}

///|
pub fn float_note_set_source_mode(
  note : FloatNote,
  source_mode : Bool,
) -> FloatNote {
  if source_mode == note.source_mode {
    return note
  }
  { ..note, source_mode, }
}
