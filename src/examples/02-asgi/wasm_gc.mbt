// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// wasm-gc has no event loop to await a request on, so the traced application in
/// `main.mbt` is built for the other three targets. This build says so instead of
/// compiling something that only looks like the example.
///
///     moon run src/examples/02-asgi --target wasm-gc
#coverage.skip
fn main {
  println(
    "This example drives an ASGI application and needs an async runtime, which wasm-gc does not have here.",
  )
  println("Run it on native, wasm or js: moon run src/examples/02-asgi")
}
