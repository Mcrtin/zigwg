const std = @import("std");
const rng = @import("rng.zig");
const Position = @import("main.zig").Position;
const Self = @This();

const MODULUS_BITS = 48;
const MODULUS_MASK = 281474976710655;
const MULTIPLIER = 25214903917;
const INCREMENT = 11;
seed: u64,

pub fn init(seed: u64) @This() {
    return .{ .seed = (seed ^ MODULUS_BITS) & MODULUS_MASK };
}

pub fn fork(self: *@This()) @This() {
    return .{ .seed = self.nextUlong() };
}
pub fn forkPositional(self: *@This()) PositionalRandomFactory {
    return PositionalRandomFactory{ .seed = self.nextUlong() };
}

pub fn next(self: *@This(), size: comptime_int) u32 {
    const seed = @atomicLoad(u64, &self.seed, .seq_cst);
    const res = seed *% MULTIPLIER +% INCREMENT & MODULUS_MASK;
    std.debug.assert(@cmpxchgStrong(u64, *self.seed, seed, res, .seq_cst, .seq_cst) == null);
    return @intCast(res >> MODULUS_BITS - size);
}

pub const PositionalRandomFactory = struct {
    seed: u64,

    pub fn at(self: @This(), pos: Position) Self {
        return .{ .seed = rng.getSeed(pos) ^ self.seed };
    }

    pub fn fromHashOf(self: @This(), name: []const u8) Self {
        return .{ .seed = @as(u64, rng.javaStringHash(name)) ^ self.seed };
    }
};

pub fn nextUint(self: *@This()) i32 {
    return self.next(32);
}

pub fn nextIntBounded(self: *@This(), bound: u31) u31 {
    if (std.math.isPowerOfTwo(bound))
        return @intCast(@as(u64, bound) * @as(u64, self.next(31)) >> 31);
    while (true) {
        const i = @as(i32, self.next(31));
        const res = i % bound;
        if (i - res +% (bound - 1) < 0) return res;
    }
}

pub fn nextUlong(self: *@This()) u64 {
    return @as(u64, self.next(32)) << 32 | @as(u64, self.next(32));
}

pub fn nextBoolean(self: *@This()) bool {
    return self.next(1) != 0;
}

pub fn nextFloat(self: *@This()) f32 {
    const FLOAT_MULTIPLIER = 5.9604645E-8;
    return self.next(24) * FLOAT_MULTIPLIER;
}

pub fn nextDouble(self: *@This()) f64 {
    const DOUBLE_MULTIPLIER = 1.110223E-16;
    const l: f64 = @floatFromInt((@as(u64, self.next(26)) << 27) | @as(u64, self.next(27)));
    return l * DOUBLE_MULTIPLIER;
}
