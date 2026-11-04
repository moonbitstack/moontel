// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// `#tel.span` on a free function, turned into `<name>_traced`, which runs it inside a span. The
/// function itself is not touched, since a generator can only add code.
priv struct Span {}

///|
impl @gen.Generator for Span with fn name(_) {
  "moontel span"
}

///|
let span_spec : @attr.Spec = @attr.Spec::new("tel.span")
  .positional("name", Str, optional=true)
  .optional("kind", Ident)
  .many("attr", Str)

///|
/// The names a wrapper adds to the function's own parameters.
let reserved : Array[String] = ["tracer", "now", "parent", "span"]

///|
fn at(attr : @attribute.Attribute, file : String) -> String {
  "\{file}:\{attr.loc.start.lnum}:\{attr.loc.start.column()}"
}

///|
/// The constructor a `kind=` names.
fn kind_of(name : String, where_ : String) -> String raise {
  match name {
    "internal" => "@trace.Internal"
    "server" => "@trace.Server"
    "client" => "@trace.Client"
    "producer" => "@trace.Producer"
    "consumer" => "@trace.Consumer"
    _ =>
      fail(
        "\{where_}: `kind` is internal, server, client, producer or consumer, not `\{name}`",
      )
  }
}

///|
/// A parameter as the attribute value a span can carry.
fn attribute_of(
  key : String,
  params : Array[@gen.Param],
  where_ : String,
) -> String raise {
  guard params.iter().find_first(p => p.name == Some(key)) is Some(param) else {
    fail("\{where_}: there is no parameter `\{key}` to record")
  }
  guard param.pass is (Positional | Labelled) else {
    fail("\{where_}: `\{key}` may be left out, so it cannot be recorded")
  }
  let value = match param.ty {
    Some("String") => "@trace.Str(\{key})"
    Some("Bool") => "@trace.Bool(\{key})"
    Some("Double") => "@trace.Double(\{key})"
    Some("Int64") => "@trace.Int(\{key})"
    Some("Int" | "Int32" | "UInt" | "UInt32") => "@trace.Int(\{key}.to_int64())"
    Some(other) =>
      fail(
        "\{where_}: `\{key}` is a \{other}; a span records text, numbers and booleans",
      )
    None => fail("\{where_}: `\{key}` has no type to record it by")
  }
  "(\{@quote.string(key)}, \{value})"
}

///|
/// The wrapper of one annotated function.
fn wrapper(
  note : @attribute.Attribute,
  name : String,
  params : Array[@gen.Param],
  returns : String?,
  is_async : Bool,
  public : Bool,
  raises : String,
  file : String,
) -> String raise {
  let where_ = at(note, file)
  let args = span_spec.bind(note)
  let declared = ["tracer : @trace.Tracer"]
  let passed = []
  for param in params {
    guard param.declared() is Some(d) && param.passed() is Some(p) else {
      fail(
        "\{where_}: the arguments of a traced function are passed on, so they are named and typed",
      )
    }
    if param.name is Some(taken) && reserved.contains(taken) {
      fail(
        "\{where_}: the wrapper has its own `\{taken}`; rename this parameter",
      )
    }
    declared.push(d)
    passed.push(p)
  }
  declared.push("now~ : () -> Int64")
  declared.push("parent? : @trace.TraceContext")
  let extras = []
  match args.get("kind") {
    [] => ()
    [Ident(kind)] => extras.push("kind=\{kind_of(kind, where_)}")
    _ => fail("\{where_}: `kind` is a name such as `server`")
  }
  let recorded = []
  for key in args.strs("attr") {
    recorded.push(attribute_of(key, params, where_))
  }
  if recorded is [_, ..] {
    extras.push("attributes=[\{recorded.join(", ")}]")
  }
  let title = @quote.string(args.str("name").unwrap_or(name))
  let start = ["parent?", "at=now()", ..extras].join(", ")
  let vis = if public { "pub " } else { "" }
  let run = if is_async { "async " } else { "" }
  let result = returns.unwrap_or("Unit")
  let call = "\{name}(\{passed.join(", ")})"
  // Starting a span can raise, so a wrapper raises even when the function does not.
  let tail = if raises == "" { "raise @trace.Refused" } else { "raise" }
  // Through a closure that raises any error, because `Error` is the type that can always be
  // printed, and a function's own error type need not be.
  let body = if raises == "" {
    call
  } else {
    (
      $|let run : \{run}() -> \{result} raise = () => \{call}
      $|  match (try Ok(run()) catch { e => Err(e) }) {
      $|    Ok(value) => value
      $|    Err(e) => {
      $|      span.record_exception(message=e.to_string(), at=now())
      $|      span.set_status(Error(e.to_string()))
      $|      raise e
      $|    }
      $|  }
    )
  }
  (
    $|\{vis}\{run}fn \{name}_traced(\{declared.join(", ")}) -> \{result} \{tail} {
    $|  let span = tracer.start(\{title}, \{start})
    $|  defer span.finish(at=now())
    $|  \{body}
    $|}
  )
}

///|
impl @gen.Generator for Span with fn generate(_, decls) {
  let out = []
  for decl in decls {
    match decl {
      Func(
        owner~,
        name~,
        params~,
        returns~,
        is_async~,
        attrs~,
        public~,
        file~,
        ..
      ) => {
        for attr in @attr.malformed(attrs, "tel") {
          fail(
            "\{at(attr, file)}: `\{attr.raw}` does not parse as an annotation",
          )
        }
        let found = @attr.under(attrs, "tel")
        guard found is [first, ..] else { continue }
        if found.length() > 1 {
          fail("\{at(found[1], file)}: `#tel.span` is written twice")
        }
        if @attr.name_of(first) != Some("tel.span") {
          fail("\{at(first, file)}: `\{first.raw}` is not a moontel annotation")
        }
        if owner is Some(_) {
          fail("\{at(first, file)}: `#tel.span` goes on a free function")
        }
        out.push(
          wrapper(
            first,
            name,
            params,
            returns,
            is_async,
            public,
            decl.raises(),
            file,
          ),
        )
      }
      Struct(attrs~, file~, ..) | Enum(attrs~, file~, ..) =>
        if @attr.under(attrs, "tel") is [first, ..] {
          fail("\{at(first, file)}: `#tel.span` goes on a free function")
        }
      Other(..) => ()
    }
  }
  @quote.items(out.join("\n\n")).render()
}
