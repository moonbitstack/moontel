// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn flat(code : String) -> String {
  let out = StringBuilder()
  for c in code {
    if c != ' ' && c != '\n' {
      out.write_char(c)
    }
  }
  out.to_string().replace_all(old=",)", new=")").replace_all(old=",]", new="]")
}

///|
fn generate(source : String) -> String raise {
  flat(@gen.render(Span::{ }, [("m.mbt", source)]))
}

///|
fn refused(source : String) -> String {
  try {
    ignore(generate(source))
    ""
  } catch {
    e => "\{e}"
  }
}

///|
test "a span is named after the function when nothing says" {
  let code = generate("#tel.span\npub fn place(id : Int) -> Int {\n  id\n}")
  assert_true(
    code.contains(
      flat(
        "pub fn place_traced(tracer : @trace.Tracer, id : Int, now~ : () -> Int64, parent? : @trace.TraceContext) -> Int raise @trace.Refused",
      ),
    ),
  )
  assert_true(code.contains(flat("tracer.start(\"place\", parent?, at=now())")))
  assert_true(code.contains(flat("defer span.finish(at=now())")))
  // Nothing to record when the function cannot raise.
  assert_false(code.contains("record_exception"))
}

///|
test "a name, a kind and attributes go into the start" {
  let code = generate(
    "#tel.span(\"orders.place\", kind=server, attr=\"item\", attr=\"qty\")\nfn place(item : String, qty : Int) -> Int {\n  qty\n}",
  )
  assert_true(
    code.contains(
      flat(
        "tracer.start(\"orders.place\", parent?, at=now(), kind=@trace.Server, attributes=[(\"item\", @trace.Str(item)), (\"qty\", @trace.Int(qty.to_int64()))])",
      ),
    ),
  )
}

///|
test "a raising function records what it raised, and every way of passing is kept" {
  let code = generate(
    "#tel.span\npub async fn place(id : Int, tag~ : String, note? : String, retries~ : Int = 3) -> Int raise @a.Bad {\n  id\n}",
  )
  assert_true(
    code.contains(
      flat(
        "pub async fn place_traced(tracer : @trace.Tracer, id : Int, tag~ : String, note? : String, retries? : Int, now~ : () -> Int64, parent? : @trace.TraceContext) -> Int",
      ),
    ),
  )
  assert_true(code.contains(flat("() => place(id, tag~, note?, retries?)")))
  assert_true(
    code.contains(
      flat("span.record_exception(message=e.to_string(), at=now())"),
    ),
  )
  assert_true(code.contains(flat("span.set_status(Error(e.to_string()))")))
}

///|
test "what cannot work is refused where it is written" {
  let cases = [
    ("#tel.span(kind=sideways)\nfn f() -> Int {\n  1\n}", "`kind` is"),
    ("#tel.span(attr=\"x\")\nfn f() -> Int {\n  1\n}", "no parameter `x`"),
    (
      "#tel.span(attr=\"x\")\nfn f(x : Array[Int]) -> Int {\n  1\n}", "records text, numbers and booleans",
    ),
    (
      "#tel.span(attr=\"x\")\nfn f(x? : Int) -> Int {\n  1\n}", "may be left out",
    ),
    ("#tel.span\n#tel.span\nfn f() -> Int {\n  1\n}", "written twice"),
    ("#tel.trace\nfn f() -> Int {\n  1\n}", "not a moontel annotation"),
    ("#tel.span\nfn T::f(self : T) -> Int {\n  1\n}", "free function"),
    ("#tel.span\nstruct S {\n  x : Int\n}", "free function"),
    ("#tel.span(type=\"x\")\nfn f() -> Int {\n  1\n}", "does not parse"),
    ("#tel.span\nfn f(_ : Int) -> Int {\n  1\n}", "named and typed"),
    ("#tel.span\nfn f(now : Int) -> Int {\n  1\n}", "has its own `now`"),
  ]
  for case in cases {
    let (source, expected) = case
    let got = refused(source)
    assert_true(got.contains(expected), msg="\{source} gave: \{got}")
  }
}

///|
test "a file with no annotation writes nothing" {
  assert_false(generate("fn f() -> Int {\n  1\n}").contains("_traced"))
}
