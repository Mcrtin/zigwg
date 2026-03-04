const std = @import("std");
const rng = @import("rng.zig");
const mf64 = @import("zlm").as(f64);
const mi32 = @import("zlm").as(i32);
const math = @import("math.zig");

pub const ImprovedSimplex = struct {
    pub const max_value = 2.0;
    simplex: Simplex,
    pub fn init(rng_type: type, random: *rng.Rng(rng_type)) @This() {
        return .{ .simplex = .init(rng_type, random) };
    }

    const SHIFT_UP_EPSILON = 1.0E-7;

    pub fn noise(self: *const @This(), pos: mf64.Vec3) f64 {
        return self.noiseDeprecated(pos, 0.0, 0.0);
    }

    pub fn noiseDeprecated(self: *const @This(), pos: mf64.Vec3, yScale: f64, yMax: f64) f64 {
        const offset = self.simplex.offset.add(pos);
        const floored: mf64.Vec3 = .new(@floor(offset.x), @floor(offset.y), @floor(offset.z));
        const grid: mi32.Vec3 = .new(@intFromFloat(floored.x), @intFromFloat(floored.y), @intFromFloat(floored.z));
        const rem = offset.sub(floored);
        const yoffset = if (yScale != 0.0)
            @floor(if (0 <= yMax and yMax < rem.y) yMax else rem.y / yScale + 1.0E-7) * yScale
        else
            0.0;

        return self.sampleAndLerp(grid, rem, rem.y - yoffset);
    }

    fn dot(gradIndex: u8, pos: mf64.Vec3) f64 {
        return Simplex.GRADIENT[gradIndex & 15].dot(pos);
    }

    inline fn p(self: *const @This(), index: u8) u8 {
        return self.simplex.permutation[index];
    }

    fn sampleAndLerp(self: *const @This(), grid: mi32.Vec3, delta: mf64.Vec3, weirdDeltaY: f64) f64 {
        const weird_delta: mf64.Vec3 = .new(delta.x, weirdDeltaY, delta.z);
        const x: u8 = @truncate(@as(u32, @bitCast(grid.x)));
        const y: u8 = @truncate(@as(u32, @bitCast(grid.y)));
        const z: u8 = @truncate(@as(u32, @bitCast(grid.z)));
        var args: std.meta.ArgsTuple(@TypeOf(math.lerp3)) = undefined;
        args[0] = smoothstep(delta.x);
        args[1] = smoothstep(delta.y);
        args[2] = smoothstep(delta.z);
        inline for (0b000..0b111) |i| {
            const curr: u8 = @intCast(i);
            const xo = curr & 1;
            const yo = (curr >> 1) & 1;
            const zo = curr >> 2;
            args[3 + i] = dot(self.p(self.p(self.p(x +% xo) +% y +% yo) +% z +% zo), weird_delta.sub(.new(xo, yo, zo)));
        }
        return @call(.auto, math.lerp3, args);
        // const int0 = self.p(x);
        // const int1 = self.p(x +% 1);
        // const int2 = self.p(int0 +% y);
        // const int3 = self.p(int0 +% y +% 1);
        // const int4 = self.p(int1 +% y);
        // const int5 = self.p(int1 +% y +% 1);
        // const d0 = dot(self.p(int2 +% z), .new(delta.x, weirdDeltaY, delta.z));
        // const d1 = dot(self.p(int4 +% z), .new(delta.x - 1.0, weirdDeltaY, delta.z));
        // const d2 = dot(self.p(int3 +% z), .new(delta.x, weirdDeltaY - 1.0, delta.z));
        // const d3 = dot(self.p(int5 +% z), .new(delta.x - 1.0, weirdDeltaY - 1.0, delta.z));
        // const d4 = dot(self.p(int2 +% z +% 1), .new(delta.x, weirdDeltaY, delta.z - 1.0));
        // const d5 = dot(self.p(int4 +% z +% 1), .new(delta.x - 1.0, weirdDeltaY, delta.z - 1.0));
        // const d6 = dot(self.p(int3 +% z +% 1), .new(delta.x, weirdDeltaY - 1.0, delta.z - 1.0));
        // const d7 = dot(self.p(int5 +% z +% 1), .new(delta.x - 1.0, weirdDeltaY - 1.0, delta.z - 1.0));
        // return math.lerp3(smoothstep(delta.x), smoothstep(delta.y), smoothstep(delta.z), d0, d1, d2, d3, d4, d5, d6, d7);
    }
    fn smoothstep(input: f64) f64 {
        return input * input * input * (input * (input * 6.0 - 15.0) + 10.0);
    }
};

pub const Simplex = struct {
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
    permutation: [256]u8 = blk: {
        var res: [256]u8 = undefined;
        for (&res, 0..) |*item, i| item.* = i;
        break :blk res;
    },

    pub fn init(rng_type: type, random: *rng.Rng(rng_type)) @This() {
        var res: @This() = .{ .offset = .new(random.nextDouble() * 256.0, random.nextDouble() * 256.0, random.nextDouble() * 256.0) };
        for (&res.permutation, 0..) |*item, i| {
            const idx: u8 = @intCast(i);
            const random_idx: u8 = @intCast(random.nextIntBounded(256 - @as(u9, idx)));
            std.mem.swap(u8, item, &res.permutation[random_idx + idx]);
        }
        return res;
    }

    inline fn p(self: *const @This(), index: anytype) u8 {
        return self.permutation[@as(usize, index & 0xff)];
    }

    fn getCornerNoise3D(gradientIndex: u8, pos: mf64.Vec3, offset: f64) f64 {
        const d = offset - pos.length2();
        return if (d < 0.0)
            0.0
        else
            d * d * d * d * GRADIENT[gradientIndex].dot(pos);
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
        const d6 = d4 - i + G2;
        const d7 = d5 - int1 + G2;
        const d8 = d4 - 1.0 + 2.0 * G2;
        const d9 = d5 - 1.0 + 2.0 * G2;
        const int2 = floor & 0xFF;
        const int3 = floor1 & 0xFF;
        const int4 = self.p(int2 + self.p(int3)) % 12;
        const int5 = self.p(int2 + i + self.p(int3 + int1)) % 12;
        const int6 = self.p(int2 + 1 + self.p(int3 + 1)) % 12;
        const corner1 = getCornerNoise3D(int4, d4, d5, 0.0, 0.5);
        const corner2 = getCornerNoise3D(int5, d6, d7, 0.0, 0.5);
        const corner3 = getCornerNoise3D(int6, d8, d9, 0.0, 0.5);
        return 70.0 * (corner1 + corner2 + corner3);
    }
};
