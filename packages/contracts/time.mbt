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
