// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// How urgent a record is.
///
/// The six names are the ranges OpenTelemetry reserves in its severity number
/// space, and the number each one reports is the first of its four slots: a
/// backend that sorts on the number puts an `Info` record above every `Debug`
/// record and below every `Warn` record, whatever the gaps between them.
#derive(Eq, Debug)
pub(all) enum Severity {
  Trace
  Debug
  Info
  Warn
  Error
  Fatal
}

///|
pub extend Severity with Eq::{equal, not_equal}

///|
pub extend Severity with Debug::{to_repr}

///|
/// The severity number, which is what an OTLP export carries: `TRACE` 1, `DEBUG`
/// 5, `INFO` 9, `WARN` 13, `ERROR` 17, `FATAL` 21 (OpenTelemetry logs data model,
/// "Severity Number").
pub fn Severity::number(self : Severity) -> Int32 {
  match self {
    Trace => 1
    Debug => 5
    Info => 9
    Warn => 13
    Error => 17
    Fatal => 21
  }
}

///|
/// The severity text: the short name a human reads, and the value OTLP carries in
/// `severityText` when the record does not spell its own.
pub fn Severity::text(self : Severity) -> String {
  match self {
    Trace => "TRACE"
    Debug => "DEBUG"
    Info => "INFO"
    Warn => "WARN"
    Error => "ERROR"
    Fatal => "FATAL"
  }
}

///|
/// Whether this severity is at least as urgent as `floor`, which is how a minimum
/// level filters a stream of records.
pub fn Severity::at_least(self : Severity, floor : Severity) -> Bool {
  self.number() >= floor.number()
}

///|
/// The severity a name stands for, matched without regard to case, or `None` for a
/// name this enum does not have. Reading a level out of configuration is the one
/// place a string has to become a `Severity`.
pub fn Severity::of_name(name : StringView) -> Severity? {
  match name.to_lower() {
    "trace" => Some(Trace)
    "debug" => Some(Debug)
    "info" => Some(Info)
    "warn" | "warning" => Some(Warn)
    "error" => Some(Error)
    "fatal" => Some(Fatal)
    _ => None
  }
}
