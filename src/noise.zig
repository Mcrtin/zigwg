const std = @import("std");
const rng = @import("rng.zig");
const mf64 = @import("zlm").as(f64);
const math = @import("math.zig");
const perlin = @import("perlin_noise.zig");

pub const NoiseData = struct { firstOctave: i32, amplitudes: []const f64 };

pub inline fn createLegacyNetherBiome(rng_type: type, random: *rng.Rng(rng_type), comptime octsAndAmps: struct { firstOctave: i32, amplitudes: []const f64 }) NormalNoise(octsAndAmps.amplitudes.len) {
    return .init(random, octsAndAmps, false);
}

pub inline fn create(rng_type: type, random: *rng.Rng(rng_type), comptime octsAndAmps: struct { firstOctave: i32, amplitudes: []const f64 }) NormalNoise(octsAndAmps.amplitudes.len) {
    return create(random, octsAndAmps, true);
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
            const first_non_zero = blk: {
                for (amps, 0..) |amp, i| (if (amp != 0)
                    break :blk i) else unreachable;
            };

            var it = std.mem.reverseIterator(amps);
            var i = amps.len;
            const last_non_zero = blk: {
                while (it.next()) |amp| : (i -= 1) (if (amp != 0) break :blk i) else unreachable;
            };

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
            return (self.first.getValue(pos) + self.second.getValue(pos.mul(.new(INPUT_FACTOR, INPUT_FACTOR, INPUT_FACTOR)))) * self.valueFactor;
        }
    };
}

pub const Blended = struct {
    minLimitNoise: perlin.Perlin(16),
    maxLimitNoise: perlin.Perlin(16),
    mainNoise: perlin.Perlin(8),

    pub fn create(rng_type: type, random: *rng.Rng(rng_type)) @This() {
        const limit_octaves = comptime math.range(i32, -15, 1);
        return .{
            .minLimitNoise = perlin.createLegacyForBlendedNoise(rng_type, random, &limit_octaves),
            .maxLimitNoise = perlin.createLegacyForBlendedNoise(rng_type, random, &limit_octaves),
            .mainNoise = perlin.createLegacyForBlendedNoise(rng_type, random, &math.range(i32, -7, 1)),
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
            const factored_pos_scaled = factored_pos.mul(.new(scale, scale, scale));
            const wrapped_factored_pos_scaled: mf64.Vec3 = .new(perlin.wrap(factored_pos_scaled.x), perlin.wrap(factored_pos_scaled.y), perlin.wrap(factored_pos_scaled.z));
            main_noise_res += noise.noiseDeprecated(wrapped_factored_pos_scaled, factored_smear_y_mult * scale, factored_pos_scaled.y) / scale;
            scale /= 2.0;
        }

        const res = (main_noise_res / 10.0 + 1.0) / 2.0;
        scale = 1.0;

        if (res < 1) {
            var it2 = std.mem.reverseIterator(&self.minLimitNoise.noiseLevels);
            while (it2.next()) |noise| {
                const scaled_pos_scaled = scaled_pos.mul(.new(scale, scale, scale));
                const wrapped_scaled_pos_scaled: mf64.Vec3 = .new(perlin.wrap(scaled_pos_scaled.x), perlin.wrap(scaled_pos_scaled.y), perlin.wrap(scaled_pos_scaled.z));
                start += noise.noiseDeprecated(wrapped_scaled_pos_scaled, smeared_y_mult * scale, scaled_pos_scaled.y) / scale;
                scale /= 2.0;
            }
        }
        scale = 1.0;
        if (res > 0) {
            var it2 = std.mem.reverseIterator(&self.maxLimitNoise.noiseLevels);
            while (it2.next()) |noise| {
                const scaled_pos_scaled = scaled_pos.mul(.new(scale, scale, scale));
                const wrapped_scaled_pos_scaled: mf64.Vec3 = .new(perlin.wrap(scaled_pos_scaled.x), perlin.wrap(scaled_pos_scaled.y), perlin.wrap(scaled_pos_scaled.z));
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
