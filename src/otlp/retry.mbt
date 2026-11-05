// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// What a reply means for the request that produced it.
///
/// The three answers are the OTLP protocol's own: an acceptance, a refusal that
/// retrying cannot fix, and a refusal that only time can. Getting the third one
/// wrong is how an exporter either gives up on a busy collector or hammers a
/// broken one.
#derive(Eq, Debug)
pub(all) enum Verdict {
  /// `2xx`, including a partial success: the request was taken, whatever the
  /// server chose to do with every record in it.
  Accepted
  /// A refusal that repeating the request would repeat. Bad data is the usual
  /// cause, and the specification says such a request MUST NOT be retried.
  Rejected
  /// A refusal that waiting may fix: `429`, `502`, `503` and `504`.
  Retry
}

///|
pub extend Verdict with Eq::{equal, not_equal}

///|
pub extend Verdict with Debug::{to_repr}

///|
/// The verdict for a status code.
///
/// The four retryable codes are the specification's table and nothing else: every
/// other `4xx` and `5xx` MUST NOT be retried, and a `3xx` that reached this point
/// came from a client that was told not to follow it.
pub fn verdict(status : Int32) -> Verdict {
  if status >= 200 && status < 300 {
    Accepted
  } else if status == 429 || status == 502 || status == 503 || status == 504 {
    Retry
  } else {
    Rejected
  }
}

///|
/// The wait a `Retry-After` value asks for, in milliseconds, or `None` when the
/// value is neither a number of seconds nor an HTTP date.
///
/// `now` is milliseconds since the Unix epoch, which is what a date has to be
/// compared against. A date in the past answers zero rather than a negative wait:
/// the server is telling this client to come back now.
pub fn retry_after_milliseconds(value : StringView, now~ : Int64) -> Int64? {
  let text = trimmed(value)
  match parse_decimal(text) {
    Some(seconds) => return Some(seconds * 1000L)
    None => ()
  }
  match http_date_milliseconds(text) {
    Some(at) => {
      let wait = at - now
      Some(if wait < 0L { 0L } else { wait })
    }
    None => None
  }
}

///|
/// A decimal integer, and nothing else: a sign, a space or a fraction is not one.
fn parse_decimal(text : StringView) -> Int64? {
  if text.length() == 0 || text.length() > 18 {
    return None
  }
  let mut value : Int64 = 0L
  for i in 0..<text.length() {
    let c = text[i].to_int()
    if c < 0x30 || c > 0x39 {
      return None
    }
    value = value * 10L + (c - 0x30).to_int64()
  }
  Some(value)
}

///|
/// The moment an IMF-fixdate names, in milliseconds since the Unix epoch.
///
/// RFC 7231 also allows two obsolete formats; a server that sends one is out of
/// date by three decades, and answering `None` lets the caller fall back to its
/// own backoff instead of guessing at a date it cannot read.
fn http_date_milliseconds(text : StringView) -> Int64? {
  // "Sun, 06 Nov 1994 08:49:37 GMT" is 29 characters, and every field sits at a
  // fixed offset, so the separators are checked rather than scanned for.
  if text.length() != 29 {
    return None
  }
  if text[3].to_int() != 0x2c ||
    text[4].to_int() != 0x20 ||
    text[7].to_int() != 0x20 ||
    text[11].to_int() != 0x20 ||
    text[16].to_int() != 0x20 ||
    text[19].to_int() != 0x3a ||
    text[22].to_int() != 0x3a ||
    text[25].to_int() != 0x20 {
    return None
  }
  if text.exact_view(start=26, end=29).to_owned() != "GMT" {
    return None
  }
  let day = match two_digits(text, 5) {
    Some(day) => day
    None => return None
  }
  let month = match month_number(text.exact_view(start=8, end=11)) {
    Some(month) => month
    None => return None
  }
  let year = match four_digits(text, 12) {
    Some(year) => year
    None => return None
  }
  let hour = match two_digits(text, 17) {
    Some(hour) => hour
    None => return None
  }
  let minute = match two_digits(text, 20) {
    Some(minute) => minute
    None => return None
  }
  let second = match two_digits(text, 23) {
    Some(second) => second
    None => return None
  }
  if hour > 23 || minute > 59 || second > 60 || day < 1 || day > 31 {
    return None
  }
  let days = days_from_civil(year, month, day)
  let seconds = hour * 3600 + minute * 60 + second
  Some(days * 86400000L + seconds.to_int64() * 1000L)
}

///|
fn two_digits(text : StringView, at : Int32) -> Int32? {
  let high = text[at].to_int()
  let low = text[at + 1].to_int()
  if high < 0x30 || high > 0x39 || low < 0x30 || low > 0x39 {
    return None
  }
  Some((high - 0x30) * 10 + (low - 0x30))
}

///|
fn four_digits(text : StringView, at : Int32) -> Int32? {
  let a = two_digits(text, at)
  let b = two_digits(text, at + 2)
  match (a, b) {
    (Some(a), Some(b)) => Some(a * 100 + b)
    _ => None
  }
}

///|
fn month_number(name : StringView) -> Int32? {
  match name.to_owned().to_upper() {
    "JAN" => Some(1)
    "FEB" => Some(2)
    "MAR" => Some(3)
    "APR" => Some(4)
    "MAY" => Some(5)
    "JUN" => Some(6)
    "JUL" => Some(7)
    "AUG" => Some(8)
    "SEP" => Some(9)
    "OCT" => Some(10)
    "NOV" => Some(11)
    "DEC" => Some(12)
    _ => None
  }
}

///|
/// Days from 1970-01-01 to `year-month-day`, counting backwards before it. The
/// proleptic Gregorian calendar, by the shift-to-March trick that keeps the leap
/// day at the end of the year.
fn days_from_civil(year : Int32, month : Int32, day : Int32) -> Int64 {
  let y = if month <= 2 { year - 1 } else { year }
  let era = if y >= 0 { y / 400 } else { (y - 399) / 400 }
  let yoe = y - era * 400
  let mp = (month + 9) % 12
  let doy = (153 * mp + 2) / 5 + day - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  (era * 146097 + doe - 719468).to_int64()
}

///|
/// `text` without the spaces and tabs around it.
fn trimmed(text : StringView) -> StringView {
  let mut lo = 0
  let mut hi = text.length()
  while lo < hi && is_space(text[lo].to_int()) {
    lo = lo + 1
  }
  while hi > lo && is_space(text[hi - 1].to_int()) {
    hi = hi - 1
  }
  text.exact_view(start=lo, end=hi)
}

///|
fn is_space(c : Int32) -> Bool {
  c == 0x20 || c == 0x09
}
