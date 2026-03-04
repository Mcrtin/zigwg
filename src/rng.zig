const std = @import("std");
const Position = @import("main.zig").Position;
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
            return self.nextIntBounded(max - min + 1) + min;
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
    const GOLDEN_RATIO_64 = 0x6a09e667f3bcc909;
    const SILVER_RATIO_64 = 0x9e3779b97f4a7c15;
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
    const x: i64 = @intCast(pos.x);
    const y: i64 = @intCast(pos.y);
    const z: i64 = @intCast(pos.z);
    const l = x *% 3129871 ^ z *% 116129781 ^ y;
    const res = l *% l *% 42317861 +% l *% 11;
    return @bitCast(res >> 16);
}
pub fn javaStringHash(bytes: []const u8) u32 {
    var h: u32 = 0;
    for (bytes) |b| h = (h *% 31) +% @as(u64, b);
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
