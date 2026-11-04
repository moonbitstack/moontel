// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
suberror Sold {
  Sold(String)
}

///|
#tel.span("orders.place", kind=server, attr="item")
fn place(item : String) -> Int32 raise Sold {
  if item == "gold" {
    raise Sold(item)
  }
  item.length()
}
