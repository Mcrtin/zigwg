const std = @import("std");
const LegacyRng = @import("LegacyRng.zig");
const rng = @import("rng.zig");
const mf64 = @import("zlm").as(f64);
const math = @import("math.zig");
const Simplex = @import("Simplex.zig");
const NoiseData = @import("noise.zig").NoiseData;

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

pub fn wrap(value: f64) f64 {
    const ROUND_OFF = 1 << 49;
    return value - @floor(value / ROUND_OFF + 0.5) * ROUND_OFF;
}
fn makeAmplitudes(comptime sorted_octaves: []const i32) NoiseData {
    std.debug.assert(std.sort.isSorted(i32, sorted_octaves, {}, struct {
        fn lessThan(_: void, a: i32, b: i32) bool {
            return a < b;
        }
    }.lessThan));
    const first = sorted_octaves[0];
    var buf: [sorted_octaves[sorted_octaves.len - 1] - first + 1]f64 = @splat(0);
    for (sorted_octaves) |octave| buf[@intCast(octave - first)] = 1;
    return .{ .firstOctave = first, .amplitudes = &buf };
}

pub fn Perlin(octave_count: comptime_int) type {
    return struct {
        const lowestFreqValueFactor: f64 = (1 << octave_count - 1) / ((1 << octave_count) - 1);
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
                    var curr_random = rng_factory.fromHashOf(std.fmt.bufPrint(&fmt_buf, "octave_{d}", .{@as(i32, @intCast(octave)) + firstOctave}) catch unreachable);
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
                .lowestFreqInputFactor = std.math.scalbn(@as(f64, 1.0), firstOctave),
            };
        }

        pub fn getValue(self: *const @This(), pos: mf64.Vec3) f64 {
            return self.getValueDeprecated(pos, 0.0, 0.0, false);
        }

        pub fn getValueDeprecated(self: *const @This(), pos: mf64.Vec3, yScale: f64, yMax: f64, useFixedY: bool) f64 {
            var freq_input_factor = self.lowestFreqInputFactor;
            var freq_value_factor = lowestFreqValueFactor;

            const input_pos = pos.mul(.new(freq_input_factor, freq_input_factor, freq_input_factor));
            const wrapped_pos: mf64.Vec3 = .new(wrap(input_pos.x), wrap(input_pos.y), wrap(input_pos.z));
            var res: f64 = 0.0;
            for (self.noiseLevels, self.amplitudes) |noise, amp| {
                res += amp * noise.noiseDeprecated(if (useFixedY) .new(wrapped_pos.x, -noise.simplex.offset.y, wrapped_pos.z) else wrapped_pos, yScale * freq_input_factor, yMax * freq_input_factor) * freq_value_factor;

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
    std.debug.assert(std.sort.isSorted(i32, octaves, {}, struct {
        fn lessThan(_: void, a: i32, b: i32) bool {
            return a < b;
        }
    }.lessThan));
    std.debug.assert(0 == -octaves[0] + 1);

    const last = octaves[octaves.len - 1];
    const len = last - octaves[0] + 1;

    const simplexNoise = Simplex.init(rng_type, random);
    var noiseLevels: [len]?Simplex = @splat(null);
    if (0 <= last and last < len and std.mem.containsAtLeastScalar(i32, octaves, 1, 0)) {
        noiseLevels[last] = simplexNoise;
    }

    for (last + 1..len) |curr| {
        const noise = Simplex.init(rng_type, random);
        if (curr >= 0 and std.mem.containsAtLeastScalar(i32, octaves, 1, last - curr))
            noiseLevels[curr] = noise;
    }

    const l: i64 = @intFromFloat(simplexNoise.getValue(simplexNoise.offset) * 9.223372E18);
    const curr_random = LegacyRng.init(@bitCast(l));
    var curr = last - 1;
    while (curr >= 0) : (curr -= 1) {
        const noise = Simplex.init(curr_random, .init(curr_random));
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
