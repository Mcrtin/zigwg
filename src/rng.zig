const std = @import("std");
const Position = @import("position.zig").Block;

pub fn Rng(T: type) type {
    return struct {
        s: T,
        pub fn init(self: T) @This() {
            return .{ .s = self };
        }

        pub fn fork(self: *@This()) @This() {
            return .init(self.s.fork());
        }

        pub fn forkPositional(self: *@This()) Factory(T) {
            return .{ .s = self.s.forkPositional() };
        }

        pub fn nextUint(self: *@This()) i32 {
            return self.s.nextUint();
        }

        pub fn nextIntBounded(self: *@This(), bound: u31) u31 {
            return self.s.nextIntBounded(bound);
        }

        pub fn nextIntBetweenInclusive(self: *@This(), min: anytype, max: anytype) @TypeOf(min, max) {
            return @intCast(self.nextIntBounded(@as(u31, max - min) + 1) + min);
        }

        pub fn nextUlong(self: *@This()) u64 {
            return self.s.nextUlong();
        }

        pub fn nextBoolean(self: *@This()) bool {
            return self.s.nextBoolean();
        }

        pub fn nextFloat(self: *@This()) f32 {
            return self.s.nextFloat();
        }

        pub fn nextDouble(self: *@This()) f64 {
            return self.s.nextDouble();
        }

        pub fn nextGaussians(self: *@This()) struct { f64, f64 } {
            while (true) {
                const d = 2.0 * self.nextDouble() - 1.0;
                const d1 = 2.0 * self.nextDouble() - 1.0;
                const d2 = d * d + d1 * d1;
                if (d2 < 1.0 and d2 != 0.0) {
                    const square_root = @sqrt(-2.0 * @log(d2) / d2);
                    return .{ d * square_root, d1 * square_root };
                }
            }
        }

        pub fn triangleDouble(self: *@This(), min: f64, max: f64) f64 {
            return min + max * (self.nextDouble() - self.nextDouble());
        }

        pub fn triangleFloat(self: *@This(), min: f32, max: f32) f32 {
            return min + max * (self.nextFloat() - self.nextFloat());
        }

        ///don't use
        pub fn consumeCount(self: *@This(), count: usize) void {
            for (0..count) |_| self.nextInt();
        }

        pub fn nextIntBetween(self: *@This(), origin: i32, bound: i32) i32 {
            return origin + @as(i32, self.nextIntBounded(@intCast(bound - origin)));
        }
    };
}
fn mixStafford13(seed: u64) u64 {
    var s = seed;
    s = (s ^ s >> 30) *% 0xbf58476d1ce4e5b9;
    s = (s ^ s >> 27) *% 0x94d049bb133111eb;
    return s ^ s >> 31;
}

pub fn upgradeSeedTo128bitUnmixed(seed: u64) [2]u64 {
    const GOLDEN_RATIO_64 = 0x9e3779b97f4a7c15;
    const SILVER_RATIO_64 = 0x6a09e667f3bcc909;
    const l = seed ^ SILVER_RATIO_64;
    const l1 = l +% GOLDEN_RATIO_64;
    return .{ l, l1 };
}

pub fn upgradeSeedTo128bit(seed: u64) [2]u64 {
    const res = upgradeSeedTo128bitUnmixed(seed);
    return .{ mixStafford13(res[0]), mixStafford13(res[1]) };
}

pub fn seedFromHashOf(string: []const u8) [2]u64 {
    const res = std.crypto.hash.Md5.hashResult(string);
    return .{ std.mem.readInt(u64, res[0..8], .big), std.mem.readInt(u64, res[8..16], .big) };
}
pub fn getDecorationSeed(rng: type, levelSeed: u64, minChunkBlockX: i32, minChunkBlockZ: i32) u64 {
    const random = rng.init(levelSeed);
    const l = random.nextLong() | 1;
    const l1 = random.nextLong() | 1;
    const l2 = minChunkBlockX *% l + minChunkBlockZ *% l1 ^ levelSeed;
    return l2;
}

pub fn getFeatureSeed(decorationSeed: u64, index: i32, decorationStep: i32) u64 {
    return decorationSeed + index + 10000 * decorationStep;
}

pub fn getLargeFeatureSeed(rng: type, baseSeed: u64, chunkX: i32, chunkZ: i32) u64 {
    const random = rng.init(baseSeed);

    const randomLong = random.nextUlong();
    const randomLong1 = random.nextUlong();
    return chunkX * randomLong ^ chunkZ * randomLong1 ^ baseSeed;
}

pub fn getLargeFeatureWithSalt(levelSeed: u64, regionX: i32, regionZ: i32, salt: i32) u64 {
    return regionX * 341873128712 + regionZ * 132897987541 + levelSeed + salt;
}

/// seed for legacy random source
pub fn geedSlimeChunk(chunkX: i32, chunkZ: i32, levelSeed: u64, salt: u64) u64 {
    return levelSeed + chunkX * chunkX * 4987142 + chunkX * 5947611 + chunkZ * chunkZ * 4392871 + chunkZ * 389711 ^ salt;
}
pub fn getSeed(pos: Position) u64 {
    const x: i64 = pos.column.x;
    const y: i64 = pos.y;
    const z: i64 = pos.column.z;
    const l = x *% 3129871 ^ z *% 116129781 ^ y;
    const res = l *% l *% 42317861 +% l *% 11;
    return @bitCast(res >> 16);
}
pub fn javaStringHash(bytes: []const u8) u32 {
    var h: u32 = 0;
    for (bytes) |b| h = (h *% 31) +% @as(u32, b);
    return h;
}

pub fn Factory(T: type) type {
    return struct {
        s: T.PositionalRandomFactory,
        pub fn at(self: @This(), pos: Position) Rng(T) {
            return .{ .s = self.s.at(pos) };
        }
        pub fn fromHashOf(self: @This(), name: []const u8) Rng(T) {
            return .{ .s = self.s.fromHashOf(name) };
        }
    };
}
pub const Xoroshiro = struct {
    s: [2]u64,

    pub fn createSequence(seed: u64, location: ?[]const u8) @This() {
        return .init(if (location) |loc|
            upgradeSeedTo128bitUnmixed(seed) ^ seedFromHashOf(loc)
        else
            upgradeSeedTo128bit(seed));
    }

    pub fn init(seed: [2]u64) @This() {
        return .{ .s = if ((seed[0] | seed[1]) == 0)
            .{ @bitCast(@as(i64, -7046029254386353131)), 7640891576956012809 }
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
        return .{ .s = upgradeSeedTo128bit(seed) };
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
        return @as(f32, @floatFromInt(self.nextBits(24))) / (1 << 24);
    }

    pub fn nextDouble(self: *@This()) f64 {
        return @floatCast(@as(f32, @floatFromInt(self.nextBits(53))) / (1 << 53));
    }

    fn nextBits(self: *@This(), bits: comptime_int) u64 {
        return self.nextUlong() >> 64 - bits;
    }

    pub const PositionalRandomFactory = struct {
        s: [2]u64,
        pub fn at(self: @This(), pos: Position) Xoroshiro {
            return .{ .s = .{ getSeed(pos) ^ self.s[0], self.s[1] } };
        }
        pub fn fromHashOf(self: @This(), name: []const u8) Xoroshiro {
            const s = seedFromHashOf(name);
            return .{ .s = .{ s[0] ^ self.s[0], s[1] ^ self.s[1] } };
        }
    };
};

pub const Legacy = struct {
    const MODULUS_BITS = 48;
    const MODULUS_MASK = 0xffffffffffff;
    const MULTIPLIER = 25214903917;
    const INCREMENT = 11;
    seed: u48,

    pub fn init(seed: u64) @This() {
        return .{ .seed = @truncate(seed ^ MULTIPLIER) };
    }

    pub fn fork(self: *@This()) @This() {
        return .{ .seed = self.nextUlong() };
    }
    pub fn forkPositional(self: *@This()) PositionalRandomFactory {
        return PositionalRandomFactory{ .seed = self.nextUlong() };
    }

    pub fn next(self: *@This(), Size: type) Size {
        comptime var Unsigned = @typeInfo(Size);
        Unsigned.int.signedness = .unsigned;
        self.seed = @truncate(@as(u64, self.seed) *% MULTIPLIER +% INCREMENT);
        return @bitCast(@as(@Type(Unsigned), @intCast(self.seed >> (MODULUS_BITS - Unsigned.int.bits))));
    }

    pub const PositionalRandomFactory = struct {
        seed: u64,

        pub fn at(self: @This(), pos: Position) Legacy {
            return .init(getSeed(pos) ^ self.seed);
        }

        pub fn fromHashOf(self: @This(), name: []const u8) Legacy {
            return .init(javaStringHash(name) ^ self.seed);
        }
    };

    pub fn nextUint(self: *@This()) u32 {
        return self.next(u32);
    }

    pub fn nextIntBounded(self: *@This(), bound: u31) u31 {
        if (std.math.isPowerOfTwo(bound))
            return @intCast(@as(u64, bound) * @as(u64, self.next(u31)) >> 31);
        return self.next(u31) % bound;
        // while (true) {
        //     const i = @as(i32, self.next(u31));
        //     const res: u31 = @intCast(@mod(i, bound));
        //     if (i - res +% (bound - 1) < 0) return res;
        // }
    }

    pub fn nextUlong(self: *@This()) u64 {
        return @bitCast((@as(i64, self.next(i32)) << 32) + @as(i64, self.next(i32)));
    }

    pub fn nextBoolean(self: *@This()) bool {
        return self.next(u1) != 0;
    }

    pub fn nextFloat(self: *@This()) f32 {
        return @as(f32, @floatFromInt(self.next(u24))) / (1 << 24);
    }

    pub fn nextDouble(self: *@This()) f64 {
        const l: f32 = @floatFromInt((@as(u64, self.next(u26)) << 27) | @as(u64, self.next(u27)));
        return @floatCast(l / (1 << 53));
    }
};

test "java string hashcode" {
    try std.testing.expectEqual(3556498, javaStringHash("test"));
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -2054162789))), javaStringHash("1234567890"));
}

test "legacy" {
    var rng = Legacy.init(0);
    const expected = [_]i32{ -1268774284, 1362668399, -881149874, 1891536193, -906589512 };
    for (expected) |exp|
        try std.testing.expectEqual(@as(u32, @bitCast(exp)), @as(u32, @truncate(rng.next(u48))));
}

test "legacy u64" {
    var rng = Rng(Legacy).init(.init(0));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, -4962768465676381896))), rng.nextUlong());
    try std.testing.expectEqual(4437113781045784766, rng.nextUlong());
}

test "legacy float" {
    var rng = Rng(Legacy).init(.init(0));
    try std.testing.expectEqual(0.73096776, rng.nextFloat());
    try std.testing.expectEqual(0.8314409852027893, rng.nextDouble());
}

test "legacy factory" {
    var rng = Rng(Legacy).init(.init(0));
    const factory = rng.forkPositional();
    try std.testing.expectEqual(198298808087495, factory.fromHashOf("test").s.seed);
    var new_rng = factory.fromHashOf("test");
    try std.testing.expectEqual(1964728489694604786, new_rng.nextUlong());
    var new_rng2 = factory.at(.init(1, 1, 1));
    try std.testing.expectEqual(6437814084537238339, new_rng2.nextUlong());
}

test "legacy bounded" {
    {
        var rng = Legacy.init(0);
        const expected = [_]u31{ 41360, 5948, 48029, 16447, 43515 };

        for (expected) |exp|
            try std.testing.expectEqual(exp, rng.nextIntBounded(100000));
    }
    {
        var rng = Legacy.init(0);
        const expected = [_]u31{ 748, 851, 246, 620, 652 };

        for (expected) |exp|
            try std.testing.expectEqual(exp, rng.nextIntBounded(1024));
    }
}

test "xoroshiro zero" {
    var rng = Rng(Xoroshiro).init(.init(.{ 0, 0 }));

    const expected = [_]i64{ 6807859099481836695, 5275285228792843439, -1883134111310439721, -7481282880567689833, -7884262219761809303 };

    for (expected) |exp|
        try std.testing.expectEqual(@as(u64, @bitCast(exp)), rng.nextUlong());
}

test "xoroshiro seeded" {
    const rng = Rng(Xoroshiro).init(.fromSeed(3257840388504953787));

    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, -6493781293903536373))), rng.s.s[0]);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, -6828912693740136794))), rng.s.s[1]);
}

test "xoroshiro fork hash" {
    var rng = Rng(Xoroshiro).init(.init(.{ 0, 0 }));
    var new_rng = rng.forkPositional().fromHashOf("test");
    try std.testing.expectEqual(8856493334125025190, new_rng.nextUlong());
}

test "xoroshiro float" {
    var rng = Rng(Xoroshiro).init(.init(.{ 0, 0 }));

    try std.testing.expectEqual(0.36905479431152344, rng.nextDouble());
    try std.testing.expectEqual(0.28597373, rng.nextFloat());
}

test "xoroshiro bounded" {
    var rng = Rng(Xoroshiro).init(.init(.{ 0, 0 }));

    try std.testing.expectEqual(4, rng.nextIntBounded(123));
    try std.testing.expectEqual(27758, rng.nextIntBounded(100_000));
}
