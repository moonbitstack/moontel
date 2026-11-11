// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn exponential_setup() -> (MeterProvider, Meter) {
  let provider = MeterProvider::new(sink=@otlp.MetricRecorder::new(), now=() => {
    0L
  })
  let meter = provider.meter(name="moontel-test")
  (provider, meter)
}

///|
/// The point of the only metric the only instrument produced.
fn exponential_point_of(provider : MeterProvider) -> @otlp.Point raise {
  let metrics = provider.collect(at=10L)
  if metrics.length() != 1 {
    fail("expected one metric, got \{metrics.length()}")
  }
  metrics[0].points[0].point
}

///|
test "a bucket holds the values above its lower bound and up to its upper one" {
  // At scale 0 bucket i covers (2^i, 2^(i+1)].
  assert_eq(exponential_index(1.0, 0), -1)
  assert_eq(exponential_index(2.0, 0), 0)
  assert_eq(exponential_index(3.0, 0), 1)
  assert_eq(exponential_index(4.0, 0), 1)
  assert_eq(exponential_index(0.5, 0), -2)
  // One step finer puts two buckets where there was one: at scale 1 bucket 1 covers
  // (2^0.5, 2^1], which is where 1.5 lands.
  assert_eq(exponential_index(1.0, 1), -1)
  assert_eq(exponential_index(1.5, 1), 1)
}

///|
test "an exponential histogram counts each measurement in its bucket" {
  let (provider, meter) = exponential_setup()
  let latency = meter.exponential_histogram("latency", unit="s", scale=0)
  latency.record(1.0, at=1L)
  latency.record(2.0, at=2L)
  latency.record(4.0, at=3L)
  match exponential_point_of(provider) {
    @otlp.ExponentialBuckets(
      scale~,
      zero_count~,
      positive_offset~,
      positive_counts~,
      negative_counts~,
      sum~,
      count~,
      min~,
      max~,
      ..
    ) => {
      assert_eq(scale, 0)
      assert_eq(zero_count, 0L)
      assert_eq(positive_offset, -1)
      assert_eq(positive_counts, [1L, 1L, 1L])
      assert_eq(negative_counts, [])
      assert_eq(sum, 7.0)
      assert_eq(count, 3L)
      assert_eq(min, Some(1.0))
      assert_eq(max, Some(4.0))
    }
    _ => fail("an exponential histogram did not export exponential buckets")
  }
}

///|
test "zero and negative measurements have their own places" {
  let (provider, meter) = exponential_setup()
  let temperature = meter.exponential_histogram("temperature", scale=0)
  temperature.record(0.0, at=1L)
  temperature.record(-3.0, at=2L)
  temperature.record(3.0, at=3L)
  match exponential_point_of(provider) {
    @otlp.ExponentialBuckets(
      zero_count~,
      positive_offset~,
      positive_counts~,
      negative_offset~,
      negative_counts~,
      count~,
      min~,
      ..
    ) => {
      assert_eq(zero_count, 1L)
      // The negative side is mirrored: -3 and 3 sit at the same index.
      assert_eq(negative_offset, positive_offset)
      assert_eq(negative_counts, positive_counts)
      assert_eq(count, 3L)
      assert_eq(min, Some(-3.0))
    }
    _ => fail("an exponential histogram did not export exponential buckets")
  }
}

///|
test "the scale drops when the measurements spread past the bucket limit" {
  let (provider, meter) = exponential_setup()
  let spread = meter.exponential_histogram("spread", scale=10, max_buckets=4)
  // Powers of two far enough apart to need four buckets of their own at scale 10.
  for i in 0..<8 {
    spread.record(@math.scalbn(1.0, i), at=i.to_int64())
  }
  match exponential_point_of(provider) {
    @otlp.ExponentialBuckets(scale~, positive_counts~, count~, ..) => {
      assert_true(scale < 10)
      assert_true(positive_counts.length() <= 4)
      assert_eq(count, 8L)
      let mut total = 0L
      for bucket in positive_counts {
        total = total + bucket
      }
      assert_eq(total, 8L)
    }
    _ => fail("an exponential histogram did not export exponential buckets")
  }
}

///|
test "the default bucket limit is the SDK's 160" {
  assert_eq(max_exponential_buckets, 160)
  let (provider, meter) = exponential_setup()
  let latency = meter.exponential_histogram("latency")
  for i in 1..<=400 {
    latency.record(i.to_double(), at=i.to_int64())
  }
  match exponential_point_of(provider) {
    @otlp.ExponentialBuckets(positive_counts~, ..) =>
      assert_true(positive_counts.length() <= max_exponential_buckets)
    _ => fail("an exponential histogram did not export exponential buckets")
  }
}

///|
test "a histogram over explicit bounds can be seen as an exponential one" {
  let recorder = @otlp.MetricRecorder::new()
  let provider = MeterProvider::new(sink=recorder, now=() => 0L, views=[
    View::new(
      instrument="latency",
      aggregation=ExponentialBuckets(scale=0, max_buckets=160),
    ),
  ])
  let meter = provider.meter(name="moontel-test")
  let latency = meter.histogram("latency", bounds=[1.0, 2.0])
  latency.record(1.5, at=1L)
  let metrics = provider.collect(at=10L)
  assert_eq(metrics[0].kind, @otlp.ExponentialHistogram(temporality=Cumulative))
  match metrics[0].points[0].point {
    @otlp.ExponentialBuckets(scale~, count~, ..) => {
      assert_eq(scale, 0)
      assert_eq(count, 1L)
    }
    _ => fail("the view did not change the aggregation")
  }
}

///|
test "merging buckets halves the scale and keeps every count where it belongs" {
  let (provider, meter) = exponential_setup()
  let spread = meter.exponential_histogram("spread", scale=0, max_buckets=2)
  // At scale 0 the three values sit in three buckets in a row: (0.5, 1], (1, 2] and
  // (2, 4]. The third one takes the count past two, so the buckets merge and the
  // scale drops.
  spread.record(0.6, at=1L)
  spread.record(1.5, at=2L)
  spread.record(3.0, at=3L)
  match exponential_point_of(provider) {
    @otlp.ExponentialBuckets(
      scale~,
      positive_offset~,
      positive_counts~,
      count~,
      ..
    ) => {
      assert_eq(scale, -1)
      // At scale -1 a bucket spans a ratio of four: 0.6 keeps a bucket of its own at
      // index -1, and the other two share index 0.
      assert_eq(positive_offset, -1)
      assert_eq(positive_counts, [1L, 2L])
      assert_eq(count, 3L)
    }
    _ => fail("an exponential histogram did not export exponential buckets")
  }
}

///|
test "a merge at a positive offset keeps the run of buckets aligned" {
  let (provider, meter) = exponential_setup()
  let spread = meter.exponential_histogram("spread", scale=0, max_buckets=2)
  // Indices 2, 3 and 4: the run starts above zero, which is where an offset that is
  // not halved alongside the counts puts them in the wrong place.
  spread.record(5.0, at=1L)
  spread.record(10.0, at=2L)
  spread.record(20.0, at=3L)
  match exponential_point_of(provider) {
    @otlp.ExponentialBuckets(scale~, positive_offset~, positive_counts~, ..) => {
      assert_eq(scale, -1)
      assert_eq(positive_offset, 1)
      assert_eq(positive_counts, [2L, 1L])
    }
    _ => fail("an exponential histogram did not export exponential buckets")
  }
}
