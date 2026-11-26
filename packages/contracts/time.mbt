///|
/// Format a Unix timestamp in milliseconds as an RFC3339 UTC string with
/// millisecond precision, e.g. `2026-11-25T12:34:56.789Z`.
///
/// M1 deliberately avoids a timezone database: the host writes UTC only.
/// The civil-date conversion is the standard days-to-civil algorithm.
pub fn format_rfc3339(ms : Int64) -> String {
  let day_ms : Int64 = 86_400_000
  let days = ms / day_ms
  let rem = ms % day_ms
  let millis = rem % 1_000
  let seconds = rem / 1_000
  let hour = seconds / 3_600
  let minute = (seconds % 3_600) / 60
  let second = seconds % 60
  let (year, month, day) = civil_from_days(days)
  pad_number(year, 4) +
  "-" +
  pad_number(month, 2) +
  "-" +
  pad_number(day, 2) +
  "T" +
  pad_number(hour, 2) +
  ":" +
  pad_number(minute, 2) +
  ":" +
  pad_number(second, 2) +
  "." +
  pad_number(millis, 3) +
  "Z"
}

///|
fn civil_from_days(days_since_epoch : Int64) -> (Int64, Int64, Int64) {
  let z = days_since_epoch + 719_468
  let era = z / 146_097
  let day_of_era = z - era * 146_097
  let year_of_era = (day_of_era -
    day_of_era / 1_460 +
    day_of_era / 36_524 -
    day_of_era / 146_096) / 365
  let year = year_of_era + era * 400
  let day_of_year = day_of_era -
    (365 * year_of_era + year_of_era / 4 - year_of_era / 100)
  let month_prime : Int64 = (5 * day_of_year + 2) / 153
  let day : Int64 = day_of_year - (153 * month_prime + 2) / 5 + 1
  let month : Int64 = if month_prime < 10 {
    month_prime + 3
  } else {
    month_prime - 9
  }
  let civil_year : Int64 = if month <= 2 { year + 1 } else { year }
  (civil_year, month, day)
}

///|
fn pad_number(value : Int64, width : Int) -> String {
  let text = value.to_string()
  let mut padding = ""
  let mut missing = width - text.length()
  while missing > 0 {
    padding = padding + "0"
    missing = missing - 1
  }
  padding + text
}

///|
/// Parse the host's UTC RFC3339 form (`YYYY-MM-DDTHH:MM:SS[.mmm]Z`) back to
/// Unix milliseconds. Approval expiry is a security boundary, so it must be
/// compared numerically rather than by lexicographic string order (which
/// would order `2026...` after `2030...`). Returns `None` for anything else.
pub fn parse_rfc3339_ms(text : String) -> Int64? {
  let with_millis = text.length() == 24 &&
    text.get_char(19) == Some('.') &&
    text.get_char(23) == Some('Z')
  let without_millis = text.length() == 20 && text.get_char(19) == Some('Z')
  if !with_millis && !without_millis {
    return None
  }
  if text.get_char(4) != Some('-') || text.get_char(7) != Some('-') ||
    text.get_char(10) != Some('T') || text.get_char(13) != Some(':') ||
    text.get_char(16) != Some(':') {
    return None
  }
  let year = match parse_digits(text, 0, 4) {
    Some(value) => value
    None => return None
  }
  let month = match parse_digits(text, 5, 7) {
    Some(value) => value
    None => return None
  }
  let day = match parse_digits(text, 8, 10) {
    Some(value) => value
    None => return None
  }
  let hour = match parse_digits(text, 11, 13) {
    Some(value) => value
    None => return None
  }
  let minute = match parse_digits(text, 14, 16) {
    Some(value) => value
    None => return None
  }
  let second = match parse_digits(text, 17, 19) {
    Some(value) => value
    None => return None
  }
  let millis = if with_millis {
    match parse_digits(text, 20, 23) {
      Some(value) => value
      None => return None
    }
  } else {
    0
  }
  if year < 1970 || month < 1 || month > 12 || day < 1 || day > 31 ||
    hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 ||
    second > 59 || millis < 0 || millis > 999 {
    return None
  }
  let days = days_from_civil(
    year.to_int64(),
    month.to_int64(),
    day.to_int64(),
  )
  let time_ms = (hour.to_int64() * 3_600L + minute.to_int64() * 60L +
    second.to_int64()) * 1_000L + millis.to_int64()
  Some(days * 86_400_000L + time_ms)
}

///|
fn parse_digits(text : String, start : Int, end : Int) -> Int? {
  let mut value = 0
  let mut index = start
  while index < end {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => return None
    }
    let code = ch.to_int()
    if code < 48 || code > 57 {
      return None
    }
    value = value * 10 + (code - 48)
    index = index + 1
  }
  Some(value)
}

///|
fn days_from_civil(year : Int64, month : Int64, day : Int64) -> Int64 {
  let adjusted_year = if month <= 2L { year - 1L } else { year }
  let era = adjusted_year / 400L
  let year_of_era = adjusted_year - era * 400L
  let shifted_month = if month > 2L { month - 3L } else { month + 9L }
  let day_of_year = (153L * shifted_month + 2L) / 5L + day - 1L
  let day_of_era = year_of_era * 365L + year_of_era / 4L -
    year_of_era / 100L + day_of_year
  era * 146_097L + day_of_era - 719_468L
}
