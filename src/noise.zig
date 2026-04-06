const std = @import("std");
const rng = @import("rng.zig");
const mi32 = @import("zlm").as(i32);
const mf64 = @import("zlm").as(f64);
const math = @import("math.zig");
const mcg = @import("mc-generated");
//TODO NoisePos;

pub const NoiseData = mcg.worldgen.noise;

pub inline fn createLegacyNetherBiome(rng_type: type, random: *rng.Rng(rng_type), comptime octsAndAmps: mcg.worldgen.noise) NormalNoise(octsAndAmps.amplitudes.len) {
    return .init(rng_type, random, octsAndAmps, false);
}

pub inline fn create(rng_type: type, random: *rng.Rng(rng_type), comptime octsAndAmps: mcg.worldgen.noise) NormalNoise(octsAndAmps.amplitudes.len) {
    return .init(rng_type, random, octsAndAmps, true);
}

pub fn NormalNoise(octave_count: comptime_int) type {
    return struct {
        pub const octaves = octave_count;
        valueFactor: f64,
        first: perlin.Perlin(octave_count),
        second: perlin.Perlin(octave_count),

        pub fn init(rng_type: type, random: *rng.Rng(rng_type), comptime noise_data: NoiseData, useNewFactory: bool) @This() {
            const amps = noise_data.amplitudes;

            //TODO: first should always be non zero
            const first_non_zero = std.mem.indexOfNone(f64, amps, &.{0}).?;
            const last_non_zero = std.mem.lastIndexOfNone(f64, amps, &.{0}).?;

            // const TARGET_DEVIATION = 0.3333333333333333;
            const valueFactor = 0.16666666666666666 / expectedDeviation(last_non_zero - first_non_zero);
            return .{
                .valueFactor = valueFactor,
                .first = if (useNewFactory)
                    perlin.create(rng_type, random, noise_data)
                else
                    perlin.createLegacyForLegacyNetherBiome(rng_type, random, noise_data),
                .second = if (useNewFactory)
                    perlin.create(rng_type, random, noise_data)
                else
                    perlin.createLegacyForLegacyNetherBiome(rng_type, random, noise_data),
            };
        }

        pub fn maxValue(self: *const @This()) f64 {
            return (self.first.maxValue() + self.second.maxValue()) * self.valueFactor;
        }

        fn expectedDeviation(actual_octaves: usize) f64 {
            return 0.1 * (1.0 + 1.0 / (@as(f64, @floatFromInt(actual_octaves)) + 1));
        }

        pub fn getValue(self: *const @This(), pos: mf64.Vec3) f64 {
            const INPUT_FACTOR = 1.0181268882175227;
            return (self.first.getValue(pos) + self.second.getValue(pos.scale(INPUT_FACTOR))) * self.valueFactor;
        }
    };
}

pub const Blended = struct {
    minLimitNoise: perlin.Perlin(16),
    maxLimitNoise: perlin.Perlin(16),
    mainNoise: perlin.Perlin(8),

    pub fn create(rng_type: type, random: *rng.Rng(rng_type)) @This() {
        const limit_octaves = comptime math.range(i32, -15, 0);
        return .{
            .minLimitNoise = perlin.createLegacyForBlendedNoise(rng_type, random, &limit_octaves),
            .maxLimitNoise = perlin.createLegacyForBlendedNoise(rng_type, random, &limit_octaves),
            .mainNoise = perlin.createLegacyForBlendedNoise(rng_type, random, &math.range(i32, -7, 0)),
        };
    }

    pub fn compute(self: *const @This(), pos: mf64.Vec3, xzScale: f64, yScale: f64, xzFactor: f64, yFactor: f64, smearScaleMultiplier: f64) f64 {
        const xzMultiplier = 684.412 * xzScale;
        const yMultiplier = 684.412 * yScale;
        const scaled_pos = pos.mul(.new(xzMultiplier, yMultiplier, xzMultiplier));
        const factored_pos = scaled_pos.div(.new(xzFactor, yFactor, xzFactor));
        const smeared_y_mult = yMultiplier * smearScaleMultiplier;
        const factored_smear_y_mult = smeared_y_mult / yFactor;
        var start: f64 = 0.0;
        var end: f64 = 0.0;
        var main_noise_res: f64 = 0.0;
        var scale: f64 = 1.0;

        var it = std.mem.reverseIterator(&self.mainNoise.noiseLevels);
        while (it.next()) |noise| {
            const factored_pos_scaled = factored_pos.scale(scale);
            const wrapped_factored_pos_scaled: mf64.Vec3 = .new(perlin.round(factored_pos_scaled.x), perlin.round(factored_pos_scaled.y), perlin.round(factored_pos_scaled.z));
            main_noise_res += noise.noiseDeprecated(wrapped_factored_pos_scaled, factored_smear_y_mult * scale, factored_pos_scaled.y) / scale;
            scale /= 2.0;
        }

        const res = (main_noise_res / 10.0 + 1.0) / 2.0;
        scale = 1.0;

        if (res < 1) {
            var it2 = std.mem.reverseIterator(&self.minLimitNoise.noiseLevels);
            while (it2.next()) |noise| {
                const scaled_pos_scaled = scaled_pos.scale(scale);
                const wrapped_scaled_pos_scaled: mf64.Vec3 = .new(perlin.round(scaled_pos_scaled.x), perlin.round(scaled_pos_scaled.y), perlin.round(scaled_pos_scaled.z));
                start += noise.noiseDeprecated(wrapped_scaled_pos_scaled, smeared_y_mult * scale, scaled_pos_scaled.y) / scale;
                scale /= 2.0;
            }
        }
        scale = 1.0;
        if (res > 0) {
            var it2 = std.mem.reverseIterator(&self.maxLimitNoise.noiseLevels);
            while (it2.next()) |noise| {
                const scaled_pos_scaled = scaled_pos.scale(scale);
                const wrapped_scaled_pos_scaled: mf64.Vec3 = .new(perlin.round(scaled_pos_scaled.x), perlin.round(scaled_pos_scaled.y), perlin.round(scaled_pos_scaled.z));

                end += noise.noiseDeprecated(wrapped_scaled_pos_scaled, smeared_y_mult * scale, scaled_pos_scaled.y) / scale;
                scale /= 2.0;
            }
        }

        return math.clampedLerp(res, start / 512.0, end / 512.0) / 128.0;
    }

    pub fn minValue(self: *const @This()) f64 {
        return -self.maxValue();
    }
    pub fn maxValue(self: *const @This()) f64 {
        return self.minLimitNoise.maxBrokenValue(self.yMultiplier);
    }
};

test "noise normal" {
    var random = rng.Rng(rng.Xoroshiro).init(.init(.{ 0, 0 }));
    const factory = random.forkPositional();
    var rand = factory.fromHashOf("minecraft:test");
    const noise = create(rng.Xoroshiro, &rand, .{ .firstOctave = -4, .amplitudes = &.{ 2.0, 1.5, 0.1, -1.0, 0.0, 0.0 } });

    try std.testing.expectEqual(1.3333333333333333, noise.valueFactor);
    try std.testing.expectEqual(0.3623879633162622, noise.getValue(.zero));
    try std.testing.expectEqual(-0.10086538185785067, noise.getValue(.new(10000.123, 203.5, -20031.78)));
}

test "noise blended" {
    var random = rng.Rng(rng.Xoroshiro).init(.fromSeed(0));
    const noise: Blended = .create(rng.Xoroshiro, &random);
    try std.testing.expectEqual(0.05283812245734512, noise.compute(.zero, 0.25, 0.125, 80, 160, 8));
    try std.testing.expectEqual(0.23586573475625464, noise.compute(.new(10000, 203, -20031), 0.25, 0.125, 80, 160, 8));
}
pub const Simplex = struct {
    pub const Improved = struct {
        pub const max_value = 2.0;
        simplex: Simplex,
        pub fn init(rng_type: type, random: *rng.Rng(rng_type)) @This() {
            return .{ .simplex = .init(rng_type, random) };
        }

        pub fn noise(self: *const @This(), pos: mf64.Vec3) f64 {
            return self.noiseDeprecated(pos, 0.0, 0.0);
        }

        pub fn noiseDeprecated(self: *const @This(), pos: mf64.Vec3, yScale: f64, yMax: f64) f64 {
            const offset = pos.add(self.simplex.offset);

            const floored: mf64.Vec3 = .new(@floor(offset.x), @floor(offset.y), @floor(offset.z));
            const grid: mi32.Vec3 = .new(@intFromFloat(floored.x), @intFromFloat(floored.y), @intFromFloat(floored.z));
            const delta = offset.sub(floored);
            const SHIFT_UP_EPSILON = 1.0E-7;
            const yoffset = if (yScale != 0.0)
                @floor((if (0 <= yMax and yMax < delta.y) yMax else delta.y) / yScale + SHIFT_UP_EPSILON) * yScale
            else
                0.0;

            return self.sampleAndLerp(grid, delta, delta.y - yoffset);
        }

        fn dot(gradIndex: u8, pos: mf64.Vec3) f64 {
            return Simplex.GRADIENT[gradIndex & 15].dot(pos);
        }

        inline fn p(self: *const @This(), index: u8) u8 {
            return self.simplex.permutation[index];
        }

        fn sampleAndLerp(self: *const @This(), grid: mi32.Vec3, delta: mf64.Vec3, weirdDeltaY: f64) f64 {
            const weird_delta: mf64.Vec3 = .new(delta.x, weirdDeltaY, delta.z);
            const x: u8 = @intCast(grid.x & 0xff);
            const y: u8 = @intCast(grid.y & 0xff);
            const z: u8 = @intCast(grid.z & 0xff);
            var args: std.meta.ArgsTuple(@TypeOf(math.lerp3)) = undefined;
            args[0] = smoothstep(delta.x);
            args[1] = smoothstep(delta.y);
            args[2] = smoothstep(delta.z);
            inline for (0b000..0b1000) |i| {
                const curr: u8 = @intCast(i);
                const xo = curr & 1;
                const yo = (curr >> 1) & 1;
                const zo = curr >> 2;
                args[3 + i] = dot(self.p(self.p(self.p(x +% xo) +% y +% yo) +% z +% zo), weird_delta.sub(.new(xo, yo, zo)));
            }
            return @call(.auto, math.lerp3, args);
        }

        fn smoothstep(input: f64) f64 {
            return input * input * input * (input * (input * 6.0 - 15.0) + 10.0);
        }
    };

    const GRADIENT = [_]mf64.Vec3{
        .new(1, 1, 0),
        .new(-1, 1, 0),
        .new(1, -1, 0),
        .new(-1, -1, 0),
        .new(1, 0, 1),
        .new(-1, 0, 1),
        .new(1, 0, -1),
        .new(-1, 0, -1),
        .new(0, 1, 1),
        .new(0, -1, 1),
        .new(0, 1, -1),
        .new(0, -1, -1),
        .new(1, 1, 0),
        .new(0, -1, 1),
        .new(-1, 1, 0),
        .new(0, -1, -1),
    };

    offset: mf64.Vec3,
    permutation: [256]u8 = @import("math.zig").range(u8, 0, 255),

    pub fn init(rng_type: type, random: *rng.Rng(rng_type)) @This() {
        var res: @This() = .{ .offset = .new(random.nextDouble() * 256.0, random.nextDouble() * 256.0, random.nextDouble() * 256.0) };
        for (&res.permutation, 0..) |*item, i| {
            const idx: u8 = @intCast(i);
            const random_idx: u8 = random.nextIntBetweenInclusive(0, 255 - idx);
            std.mem.swap(u8, item, &res.permutation[random_idx + idx]);
        }
        return res;
    }

    inline fn p(self: *const @This(), index: anytype) u8 {
        return self.permutation[@as(usize, index & 0xff)];
    }

    fn getCornerNoise3D(gradientIndex: u8, pos: mf64.Vec3) f64 {
        const offset = 0.5;
        const d = @max(offset - pos.x * pos.x - pos.y * pos.y - pos.z * pos.z, 0);
        return d * d * (d * d) * GRADIENT[gradientIndex & 0xf].dot(pos);
    }

    pub fn getValue(self: *const @This(), pos: mf64.Vec2) f64 {
        const F2 = 0.5 * (@sqrt(@as(f64, 3)) - 1.0);
        const G2 = (3.0 - @sqrt(@as(f64, 3))) / 6.0;
        const d = (pos.x + pos.y) * F2;
        const floor = @floor(pos.x + d);
        const floor1 = @floor(pos.y + d);
        const d1 = (floor + floor1) * G2;
        const d2 = floor - d1;
        const d3 = floor1 - d1;
        const d4 = pos.x - d2;
        const d5 = pos.y - d3;
        const i = @intFromBool(d4 > d5);
        const int1 = @intFromBool(!(d4 > d5));
        const d6 = d4 - @as(f64, @floatFromInt(i)) + G2;
        const d7 = d5 - @as(f64, @floatFromInt(int1)) + G2;
        const d8 = d4 - 1.0 + 2.0 * G2;
        const d9 = d5 - 1.0 + 2.0 * G2;
        const int2: u8 = @intCast(@as(i32, @intFromFloat(floor)) & 0xFF);
        const int3: u8 = @intCast(@as(i32, @intFromFloat(floor1)) & 0xFF);
        const int4 = self.p(int2 +% self.p(int3)) % 12;
        const int5 = self.p(int2 +% i +% self.p(int3 + int1)) % 12;
        const int6 = self.p(int2 +% 1 +% self.p(int3 + 1)) % 12;
        const corner1 = getCornerNoise3D(int4, .new(d4, d5, 0.0));
        const corner2 = getCornerNoise3D(int5, .new(d6, d7, 0.0));
        const corner3 = getCornerNoise3D(int6, .new(d8, d9, 0.0));
        return 70.0 * (corner1 + corner2 + corner3);
    }

    test "noise improved" {
        var random = rng.Rng(rng.Xoroshiro).init(.init(.{ 0, 0 }));

        const noise: Improved = .init(rng.Xoroshiro, &random);
        try std.testing.expectEqual(-0.045044799854318, noise.noise(.new(0, 0, 0)));
        try std.testing.expectEqual(-0.18708168179464396, noise.noise(.new(10000.123, 203.5, -20031.78)));
        try std.testing.expectEqual(-0.31263505222083193, noise.noiseDeprecated(.new(10000.123, 203.5, -20031.78), 0.5, 0.8));
    }

    test "noise improved perlin call" {
        var random = rng.Rng(rng.Xoroshiro).init(.init(.{ 0, 0 }));
        var actual_rng = random.forkPositional().fromHashOf("octave_-1");
        const noise: Improved = .init(rng.Xoroshiro, &actual_rng);
        try std.testing.expectEqual(-0.36425297083864344, noise.noise(.new(2500.03075, 50.875, -5007.945)));
    }

    test "noise simplex" {
        var random = rng.Rng(rng.Xoroshiro).init(.fromSeed(0));
        const noise: @This() = init(rng.Xoroshiro, &random);
        try std.testing.expectEqual(0, noise.getValue(.new(0, 0)));
        try std.testing.expectEqual(0.16818932411152746, noise.getValue(.new(10000, -20031)));
    }
};

pub const perlin = struct {
    pub fn createLegacyForBlendedNoise(rng_type: type, random: *rng.Rng(rng_type), comptime octaves: []const i32) Perlin(octaves[octaves.len - 1] - octaves[0] + 1) {
        return .init(rng_type, random, makeAmplitudes(octaves), false);
    }

    pub fn createLegacyForLegacyNetherBiome(rng_type: type, random: *rng.Rng(rng_type), comptime noise_data: NoiseData) Perlin(noise_data.amplitudes.len) {
        return .init(rng_type, random, noise_data, false);
    }

    pub fn createOctaves(rng_type: type, random: *rng.Rng(rng_type), comptime octaves: []const i32) Perlin(octaves.len) {
        return .init(random, makeAmplitudes(octaves), true);
    }

    pub fn create(rng_type: type, random: *rng.Rng(rng_type), comptime noise_data: NoiseData) Perlin(noise_data.amplitudes.len) {
        return .init(rng_type, random, noise_data, true);
    }

    pub fn round(value: f64) f64 {
        const ROUND_OFF: f64 = 1 << 49;
        return value - @floor(value / ROUND_OFF + 0.5) * ROUND_OFF;
    }

    fn makeAmplitudes(comptime sorted_octaves: []const i32) NoiseData {
        std.debug.assert(std.sort.isSorted(i32, sorted_octaves, {}, std.sort.asc(i32)));
        const first = sorted_octaves[0];
        var buf: [sorted_octaves[sorted_octaves.len - 1] - first + 1]f64 = @splat(0);
        for (sorted_octaves) |octave| buf[@intCast(octave - first)] = 1;
        return .{ .firstOctave = first, .amplitudes = &buf };
    }

    pub fn Perlin(comptime octave_count: u31) type {
        return struct {
            const lowestFreqValueFactor: f64 = std.math.scalbn(@as(f64, 1), octave_count - 1) / (std.math.scalbn(@as(f64, 1), octave_count) - 1);
            noiseLevels: [octave_count]Simplex.Improved,
            amplitudes: [octave_count]f64,
            lowestFreqInputFactor: f64,
            firstOctave: i32,

            fn init(rng_type: type, random: *rng.Rng(rng_type), noise_data: NoiseData, useNewFactory: bool) @This() {
                const firstOctave = noise_data.firstOctave;
                var amplitudes: [octave_count]f64 = undefined;
                @memcpy(&amplitudes, noise_data.amplitudes);
                var noiseLevels: [octave_count]Simplex.Improved = undefined;
                if (useNewFactory) {
                    const rng_factory = random.forkPositional();
                    var fmt_buf: [32]u8 = undefined;
                    for (&noiseLevels, 0..) |*noise, octave| {
                        const octave_name = std.fmt.bufPrint(&fmt_buf, "octave_{d}", .{@as(i32, @intCast(octave)) + firstOctave}) catch unreachable;
                        var curr_random = rng_factory.fromHashOf(octave_name);
                        noise.* = .init(rng_type, &curr_random);
                    }
                } else {
                    std.debug.assert(firstOctave + octave_count <= 1);
                    var i1x = -firstOctave;
                    while (i1x >= 0) : (i1x -= 1) {
                        const noise: Simplex.Improved = .init(rng_type, random);
                        if (i1x < octave_count) noiseLevels[@intCast(i1x)] = noise;
                    }
                }

                return .{
                    .amplitudes = amplitudes,
                    .noiseLevels = noiseLevels,
                    .firstOctave = firstOctave,
                    .lowestFreqInputFactor = std.math.scalbn(@as(f64, 1), firstOctave),
                };
            }

            pub fn getValue(self: *const @This(), pos: mf64.Vec3) f64 {
                return self.getValueDeprecated(pos, 0, 0, false);
            }

            pub fn getValueDeprecated(self: *const @This(), pos: mf64.Vec3, yScale: f64, yMax: f64, useFixedY: bool) f64 {
                var freq_input_factor = self.lowestFreqInputFactor;
                var freq_value_factor = lowestFreqValueFactor;

                var res: f64 = 0.0;
                for (self.noiseLevels, self.amplitudes) |noise, amp| {
                    const input_pos = pos.scale(freq_input_factor);
                    const rounded: mf64.Vec3 = .new(round(input_pos.x), round(input_pos.y), round(input_pos.z));
                    res += amp * noise.noiseDeprecated(if (useFixedY) .new(rounded.x, -noise.simplex.offset.y, rounded.z) else rounded, yScale * freq_input_factor, yMax * freq_input_factor) * freq_value_factor;

                    freq_input_factor *= 2.0;
                    freq_value_factor /= 2.0;
                }

                return res;
            }

            pub fn maxBrokenValue(self: *const @This(), yMultiplier: f64) f64 {
                return self.edgeValue(yMultiplier + Simplex.Improved.max_value);
            }

            pub fn maxValue(self: *const @This()) f64 {
                return self.edgeValue(Simplex.Improved.max_value);
            }

            fn edgeValue(self: *const @This(), noise: f64) f64 {
                const res = 0.0;
                var freqValueFactor = lowestFreqValueFactor;

                for (self.amplitudes) |amp| {
                    res += amp * noise * freqValueFactor;
                    freqValueFactor /= 2.0;
                }

                return res;
            }

            pub fn getOctaveNoise(self: *const @This(), octave: i32) Simplex.Improved {
                return self.noiseLevels[octave_count - 1 - octave];
            }
        };
    }

    pub fn initPerlinSimplex(rng_type: type, random: rng.Rng(rng_type), comptime octaves: []const i32) PerlinSimplex(octaves[octaves.len - 1] - octaves[0] + 1) {
        std.debug.assert(std.sort.isSorted(i32, octaves, {}, std.sort.asc(i32)));
        std.debug.assert(0 == -octaves[0] + 1);

        const last = octaves[octaves.len - 1];
        const len = last - octaves[0] + 1;

        const simplexNoise: Simplex = .init(rng_type, random);
        var noiseLevels: [len]?Simplex = @splat(null);
        if (0 <= last and last < len and std.mem.containsAtLeastScalar(i32, octaves, 1, 0)) {
            noiseLevels[last] = simplexNoise;
        }

        for (last + 1..len) |curr| {
            const noise: Simplex = .init(rng_type, random);
            if (curr >= 0 and std.mem.containsAtLeastScalar(i32, octaves, 1, last - curr))
                noiseLevels[curr] = noise;
        }

        const l: i64 = @intFromFloat(simplexNoise.getValue(simplexNoise.offset) * 9.223372E18);
        const curr_random = rng.Legacy.init(@bitCast(l));
        var curr = last - 1;
        while (curr >= 0) : (curr -= 1) {
            const noise: Simplex = .init(curr_random, .init(curr_random));
            if (curr < len and std.mem.containsAtLeastScalar(i32, octaves, 1, last - curr))
                noiseLevels[curr] = noise;
        }

        const highestFreqInputFactor = if (last < 0) 1.0 / (1 << last) else 1 << last;
        return .{ .noiseLevels = noiseLevels, .highestFreqInputFactor = highestFreqInputFactor };
    }

    pub fn PerlinSimplex(octave_count: comptime_int) type {
        return struct {
            const highestFreqValueFactor: f64 = 1 / ((1 << octave_count) - 1.0);
            noiseLevels: [octave_count]?Simplex,
            highestFreqInputFactor: f64,

            pub fn getValue(self: *const @This(), pos: mf64.Vec2, useNoiseOffsets: bool) f64 {
                var d = 0.0;
                var d1 = self.highestFreqInputFactor;
                var d2 = highestFreqValueFactor;

                for (self.noiseLevels) |noise| {
                    if (noise) |n| d += n.getValue(.new(pos.x * d1 + if (useNoiseOffsets) n.offset.x else 0.0, pos.y * d1 + if (useNoiseOffsets) n.offset.y else 0.0)) * d2;
                    d1 /= 2.0;
                    d2 *= 2.0;
                }

                return d;
            }
        };
    }

    test "noise perlin" {
        var random = rng.Rng(rng.Xoroshiro).init(.init(.{ 0, 0 }));
        const noise = perlin.create(rng.Xoroshiro, &random, .{ .firstOctave = -2, .amplitudes = &.{ 1.0, -1.0, 0.0, 0.5, 0.0 } });

        try std.testing.expectEqual(74.23487854003906, noise.noiseLevels[1].simplex.offset.x);
        try std.testing.expectEqual(0.25, noise.lowestFreqInputFactor);
        try std.testing.expectEqual(0.5161290322580645, @TypeOf(noise).lowestFreqValueFactor);
        try std.testing.expectEqual(-0.05992145275521602, noise.getValue(.zero));
        try std.testing.expectEqual(0.04676137080548814, noise.getValue(.new(10000.123, 203.5, -20031.78)));
    }
};
