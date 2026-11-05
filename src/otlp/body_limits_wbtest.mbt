// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "the recommended limits are the sizes the protocol names" {
  // 64 MiB out, 4 MiB back: the numbers are in the protocol's own words, so a
  // change here is a change of what "recommended" means.
  assert_eq(recommended_body_limits.request, 64 * 1024 * 1024)
  assert_eq(recommended_body_limits.response, 4 * 1024 * 1024)
}
