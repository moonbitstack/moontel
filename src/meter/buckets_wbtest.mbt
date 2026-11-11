// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "the default boundaries are the fifteen values of the metrics SDK" {
  assert_eq(default_buckets.length(), 15)
  assert_eq(default_buckets, [
    0.0, 5.0, 10.0, 25.0, 50.0, 75.0, 100.0, 250.0, 500.0, 750.0, 1000.0, 2500.0,
    5000.0, 7500.0, 10000.0,
  ])
  assert_eq(empty_counts(default_buckets).length(), 16)
  assert_eq(empty_counts(default_buckets)[15], 0L)
}

///|
test "a bucket is inclusive of its upper bound and the last one is +Inf" {
  assert_eq(bucket_index(default_buckets, -1.0), 0)
  assert_eq(bucket_index(default_buckets, 0.0), 0)
  assert_eq(bucket_index(default_buckets, 0.5), 1)
  assert_eq(bucket_index(default_buckets, 5.0), 1)
  assert_eq(bucket_index(default_buckets, 5.5), 2)
  assert_eq(bucket_index(default_buckets, 75.0), 5)
  assert_eq(bucket_index(default_buckets, 10000.0), 14)
  assert_eq(bucket_index(default_buckets, 10001.0), 15)
}

///|
test "a custom boundary list works with the same rule" {
  let bounds = [0.5, 1.0]
  assert_eq(bucket_index(bounds, 0.25), 0)
  assert_eq(bucket_index(bounds, 0.5), 0)
  assert_eq(bucket_index(bounds, 0.75), 1)
  assert_eq(bucket_index(bounds, 9.0), 2)
  assert_eq(empty_counts(bounds).length(), 3)
}
