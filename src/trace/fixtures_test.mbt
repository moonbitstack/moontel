// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A source of randomness that counts: the nth call returns `width` octets drawn
/// from `n`, so two spans never get the same id and a test can say which id a span
/// got without knowing anything about a real generator.
fn counting_rand() -> (Int32) -> Bytes {
  let calls = Ref(0)
  width => {
    calls.val = calls.val + 1
    let bytes : Array[Byte] = []
    for i in 0..<width {
      bytes.push(((calls.val * 31 + i + 1) % 251 + 1).to_byte())
    }
    Bytes::from_array(bytes)
  }
}

///|
/// A source of randomness of the right width that always says zero, which is not
/// an id any generator is allowed to produce.
fn zero_rand() -> (Int32) -> Bytes {
  width => Bytes::make(width, b'\x00')
}
