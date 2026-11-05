// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "each severity reports the first number of its range" {
  assert_eq(Severity::Trace.number(), 1)
  assert_eq(Severity::Debug.number(), 5)
  assert_eq(Severity::Info.number(), 9)
  assert_eq(Severity::Warn.number(), 13)
  assert_eq(Severity::Error.number(), 17)
  assert_eq(Severity::Fatal.number(), 21)
}

///|
test "the text of a severity is its name in capitals" {
  assert_eq(Severity::Trace.text(), "TRACE")
  assert_eq(Severity::Warn.text(), "WARN")
  assert_eq(Severity::Fatal.text(), "FATAL")
}

///|
test "a severity is at least the floor at or above it" {
  assert_true(Severity::Warn.at_least(Severity::Warn))
  assert_true(Severity::Error.at_least(Severity::Warn))
  assert_false(Severity::Info.at_least(Severity::Warn))
}

///|
test "a name becomes a severity whatever its case, and warning is warn" {
  assert_eq(Severity::of_name("info"), Some(Severity::Info))
  assert_eq(Severity::of_name("WARNING"), Some(Severity::Warn))
  assert_eq(Severity::of_name("Fatal"), Some(Severity::Fatal))
  assert_eq(Severity::of_name("verbose"), None)
}
