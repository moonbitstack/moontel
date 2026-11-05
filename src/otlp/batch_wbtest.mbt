// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "a queue refuses what it cannot hold, and counts what it refused" {
  let policy = BatchPolicy::new(queue_limit=2, batch=10, delay=1000L)
  let queue : Batch[Int32] = Batch::new(policy~)
  queue.push(1, at=0L)
  queue.push(2, at=0L)
  queue.push(3, at=0L)
  assert_eq(queue.len(), 2)
  assert_eq(queue.dropped(), 1)
}

///|
test "nothing is due before the delay has passed" {
  let policy = BatchPolicy::new(queue_limit=10, batch=5, delay=1000L)
  let queue : Batch[Int32] = Batch::new(policy~)
  queue.push(7, at=100L)
  assert_eq(queue.due(at=1099L).length(), 0)
  assert_eq(queue.len(), 1)
  let due = queue.due(at=1100L)
  assert_eq(due, [7])
  assert_eq(queue.len(), 0)

  // The wait starts again from the next arrival, not from the last flush.
  queue.push(8, at=1200L)
  assert_eq(queue.due(at=2199L).length(), 0)
  assert_eq(queue.due(at=2200L), [8])
}

///|
test "a full batch is due whatever the clock says" {
  let policy = BatchPolicy::new(queue_limit=10, batch=2, delay=60000L)
  let queue : Batch[Int32] = Batch::new(policy~)
  queue.push(1, at=0L)
  queue.push(2, at=0L)
  queue.push(3, at=0L)
  assert_eq(queue.due(at=1L), [1, 2])
  assert_eq(queue.len(), 1)
}

///|
test "a forced flush takes everything waiting" {
  let policy = BatchPolicy::new(queue_limit=10, batch=2, delay=60000L)
  let queue : Batch[Int32] = Batch::new(policy~)
  for i in 0..<4 {
    queue.push(i, at=0L)
  }
  assert_eq(queue.take_all(at=0L), [0, 1, 2, 3])
  assert_eq(queue.len(), 0)
}
