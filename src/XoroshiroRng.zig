const std = @import("std");
const rng = @import("rng.zig");
const Position = @import("main.zig").Position;

const Self = @This();

s: [2]u64,

pub fn createSequence(seed: u64, location: ?[]const u8) @This() {
    return .init(if (location) |loc|
        rng.upgradeSeedTo128bitUnmixed(seed) ^ rng.seedFromHashOf(loc)
    else
        rng.upgradeSeedTo128bit(seed));
}

pub fn init(seed: [2]u64) @This() {
    return .{ .s = if ((seed[0] | seed[1]) == 0)
        .{ -7046029254386353131, 7640891576956012809 }
    else
        seed };
}

pub fn nextUlong(self: *@This()) u64 {
    const res = std.math.rotl(u64, self.s[0] +% self.s[1], 17) +% self.s[0];
    const xor = self.s[1] ^ self.s[0];
    self.s[0] = std.math.rotl(u64, self.s[0], 49) ^ xor ^ xor << 21;
    self.s[1] = std.math.rotl(u64, xor, 28);
    return res;
}

pub fn fromSeed(seed: u64) @This() {
    return .{ .s = rng.upgradeSeedTo128bit(seed) };
}

pub fn fork(self: *@This()) @This() {
    return .{ .s = .{ self.nextUlong(), self.nextUlong() } };
}

pub fn forkPositional(self: *@This()) PositionalRandomFactory {
    return PositionalRandomFactory{ .s = .{ self.nextUlong(), self.nextUlong() } };
}

pub fn nextUint(self: *@This()) u32 {
    return @truncate(self.nextUlong());
}

pub fn nextIntBounded(self: *@This(), bound: u31) u31 {
    var l1 = @as(u64, self.nextUint()) * bound;
    var l2: u32 = @truncate(l1);
    if (l2 < bound) {
        const threshold: u32 = @as(u32, @bitCast(-%@as(i32, bound))) % bound;
        while (l2 < threshold) {
            l1 = @as(u64, self.nextUint()) * bound;
            l2 = @truncate(l1);
        }
    }
    return @truncate(l1 >> 32);
}

pub fn nextBoolean(self: *@This()) bool {
    return self.nextUlong() & 1 != 0;
}

pub fn nextFloat(self: *@This()) f32 {
    const res: f32 = @floatFromInt(self.nextBits(24));
    const FLOAT_UNIT = 5.9604645E-8;
    return res * FLOAT_UNIT;
}

pub fn nextDouble(self: *@This()) f64 {
    const res: f64 = @floatFromInt(self.nextBits(53));
    const DOUBLE_UNIT = 1.110223E-16;
    return res * DOUBLE_UNIT;
}

fn nextBits(self: *@This(), bits: comptime_int) u64 {
    return self.nextUlong() >> 64 - bits;
}

pub const PositionalRandomFactory = struct {
    s: [2]u64,
    pub fn at(self: @This(), pos: Position) Self {
        return .{ .s = .{ rng.getSeed(pos) ^ self.s[0], self.s[1] } };
    }
    pub fn fromHashOf(self: @This(), name: []const u8) Self {
        const s = rng.seedFromHashOf(name);
        return .{ .s = .{ s[0] ^ self.s[0], s[1] ^ self.s[1] } };
    }
};
