const std = @import("std");

pub fn map(input: f64, input_min: f64, input_max: f64, output_min: f64, output_max: f64) f64 {
    return lerp(inverseLerp(input, input_min, input_max), output_min, output_max);
}
pub fn clampedMap(input: f64, input_min: f64, input_max: f64, output_min: f64, output_max: f64) f64 {
    return clampedLerp(inverseLerp(input, input_min, input_max), output_min, output_max);
}

pub fn clampedLerp(delta: f64, start: f64, end: f64) f64 {
    return lerp(std.math.clamp(delta, 0.0, 1.0), start, end);
}

pub fn lerpf(delta: f32, start: f32, end: f32) f32 {
    return start + delta * (end - start);
}
pub fn lerp(delta: f64, start: f64, end: f64) f64 {
    return start + delta * (end - start);
}

pub fn inverseLerp(delta: f64, start: f64, end: f64) f64 {
    return (delta - start) / (end - start);
}

pub fn lerp2(delta1: f64, delta2: f64, start1: f64, end1: f64, start2: f64, end2: f64) f64 {
    return lerp(delta2, lerp(delta1, start1, end1), lerp(delta1, start2, end2));
}

pub fn lerp3(delta1: f64, delta2: f64, delta3: f64, start1: f64, end1: f64, start2: f64, end2: f64, start3: f64, end3: f64, start4: f64, end4: f64) f64 {
    return lerp(delta3, lerp2(delta1, delta2, start1, end1, start2, end2), lerp2(delta1, delta2, start3, end3, start4, end4));
}

pub fn range(comptime T: type, comptime start: T, comptime end_inclusive: T) [@as(usize, end_inclusive - start) + 1]T {
    var buf: [@as(usize, end_inclusive - start) + 1]T = undefined;
    for (&buf, 0..) |*item, i| item.* = @as(T, @intCast(i)) + start;
    return buf;
}

pub fn modNorm(numerator: anytype, denominator: anytype) f64 {
    return @as(f64, @floatFromInt(@mod(numerator, denominator))) / @as(f64, @floatFromInt(denominator));
}

