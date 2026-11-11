// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The most buckets one exponential histogram may use.
///
/// Source: the OpenTelemetry Metrics SDK specification, "Exponential Histogram
/// Aggregations", the `MaxSize` row of the aggregation's parameter table, which
/// states the default as 160:
/// https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/sdk.md#exponential-bucket-histogram-aggregation
///
/// A measurement whose bucket is not among the ones in use takes a new one; when
/// the count would pass this limit the buckets are merged in pairs and `scale` drops
/// by one, which is what keeps the memory one instrument may take bounded without
/// giving up resolution where the measurements actually are.
pub let max_exponential_buckets : Int32 = 160

///|
/// The finest scale the SDK defines: a bucket spans a ratio of `2^(2^-20)`, about
/// 1.00000095.
pub let max_exponential_scale : Int32 = 20

///|
/// The coarsest scale the SDK defines. At `-10` a bucket spans a ratio of `2^1024`,
/// which is wider than the range of a double, so the whole positive range is one
/// bucket.
pub let min_exponential_scale : Int32 = -10

///|
/// The bucket a positive measurement belongs to, at this scale.
///
/// Bucket `i` covers `(2^(i/2^scale), 2^((i+1)/2^scale)]`: the upper bound is part
/// of the bucket, as it is for an explicit boundary, so a value that lands exactly on
/// a boundary is counted in the lower bucket rather than the upper one.
pub fn exponential_index(value : Double, scale : Int32) -> Int32 {
  let magnification = @math.scalbn(1.0, scale)
  let position = @math.log2(value) * magnification
  @math.ceil(position).to_int() - 1
}

///|
/// The point an exponential histogram starts with: no bucket in use yet.
fn exponential_empty(scale : Int32) -> @otlp.Point {
  @otlp.ExponentialBuckets(
    scale~,
    zero_count=0L,
    positive_offset=0,
    positive_counts=[],
    negative_offset=0,
    negative_counts=[],
    sum=0.0,
    count=0L,
    min=None,
    max=None,
  )
}

///|
/// Add one measurement to an exponential histogram, merging buckets if the new one
/// would take the count past `max_buckets`.
fn exponential_record(
  point : @otlp.Point,
  value : Double,
  max_buckets : Int32,
) -> @otlp.Point {
  match point {
    @otlp.ExponentialBuckets(
      scale~,
      zero_count~,
      positive_offset~,
      positive_counts~,
      negative_offset~,
      negative_counts~,
      sum~,
      count~,
      min~,
      max~
    ) => {
      let mut scale = scale
      let mut zero_count = zero_count
      let mut positive_offset = positive_offset
      let mut positive_counts = positive_counts
      let mut negative_offset = negative_offset
      let mut negative_counts = negative_counts
      if value == 0.0 {
        zero_count = zero_count + 1L
      } else {
        // The negative side of an exponential histogram is mirrored: a negative
        // measurement is bucketed by its magnitude and counted in the other set, so
        // a reader can tell -3 from 3.
        let magnitude = if value < 0.0 { -value } else { value }
        let index = exponential_index(magnitude, scale)
        if value > 0.0 {
          let (offset, counts) = bucket_add(
            positive_offset, positive_counts, index,
          )
          positive_offset = offset
          positive_counts = counts
        } else {
          let (offset, counts) = bucket_add(
            negative_offset, negative_counts, index,
          )
          negative_offset = offset
          negative_counts = counts
        }
      }
      // Merging is what makes the scale adaptive: the resolution follows the range
      // of the measurements rather than being fixed when the instrument was made.
      while positive_counts.length() > max_buckets ||
            negative_counts.length() > max_buckets {
        if scale <= min_exponential_scale {
          break
        }
        scale = scale - 1
        let (offset, counts) = downscale(positive_offset, positive_counts)
        positive_offset = offset
        positive_counts = counts
        let (offset, counts) = downscale(negative_offset, negative_counts)
        negative_offset = offset
        negative_counts = counts
      }
      let next_min = match min {
        Some(current) => Some(if value < current { value } else { current })
        None => Some(value)
      }
      let next_max = match max {
        Some(current) => Some(if value > current { value } else { current })
        None => Some(value)
      }
      @otlp.ExponentialBuckets(
        scale~,
        zero_count~,
        positive_offset~,
        positive_counts~,
        negative_offset~,
        negative_counts~,
        sum=sum + value,
        count=count + 1L,
        min=next_min,
        max=next_max,
      )
    }
    other => other
  }
}

///|
/// One count more at `index`, in a sparse run of buckets.
///
/// The run is kept tight: a bucket below the current lowest index extends it
/// downwards rather than leaving a hole, so `offset` and the length of `counts`
/// describe exactly the buckets in use.
fn bucket_add(
  offset : Int32,
  counts : Array[Int64],
  index : Int32,
) -> (Int32, Array[Int64]) {
  if counts.length() == 0 {
    return (index, [1L])
  }
  let last = offset + counts.length() - 1
  let low = if index < offset { index } else { offset }
  let high = if index > last { index } else { last }
  let next : Array[Int64] = []
  for position in low..<=high {
    let mut value = 0L
    if position >= offset && position <= last {
      value = counts[position - offset]
    }
    if position == index {
      value = value + 1L
    }
    next.push(value)
  }
  (low, next)
}

///|
/// The same buckets at half the resolution: neighbouring pairs become one, and the
/// scale drops by one.
///
/// Old index `i` belongs to new index `floor(i / 2)`, so the arithmetic shift does
/// the whole mapping and the offset follows it.
fn downscale(offset : Int32, counts : Array[Int64]) -> (Int32, Array[Int64]) {
  let next_offset = offset >> 1
  let next : Array[Int64] = []
  for i in 0..<counts.length() {
    let slot = ((offset + i) >> 1) - next_offset
    while next.length() <= slot {
      next.push(0L)
    }
    next[slot] = next[slot] + counts[i]
  }
  // A bucket at the end that stayed empty describes nothing: `offset` and the length
  // of `counts` only have to cover the buckets in use.
  while next.length() > 0 && next[next.length() - 1] == 0L {
    next.pop() |> ignore
  }
  (next_offset, next)
}
