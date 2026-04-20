const std = @import("std");
const mcg = @import("mc-generated");
const Pos = @import("position.zig");
const NoisePos = @import("noise.zig").Position;
const math = @import("math.zig");
const PalettedContainer = @import("paletted_container.zig").PalettedContainer;

pub const Parameter = struct {
    min: i64,
    max: i64,
    pub fn from(comptime val: anytype) @This() {
        return if (@TypeOf(val) == comptime_float)
            .{ .min = quantize(val), .max = quantize(val) }
        else
            .{ .min = quantize(val[0]), .max = quantize(val[1]) };
    }
    pub fn quantize(val: f64) i64 {
        return @intFromFloat(val * 1e4);
    }
    pub fn unquantize(val: i64) f64 {
        const res: f64 = @floatFromInt(val);
        return res / 1e4;
    }
};

const Point = struct {
    continentalness: f64,
    depth: f64,
    erosion: f64,
    humidity: f64,
    temperature: f64,
    weirdness: f64,

    pub fn distance(interval: [2]f64, point: f64) i64 {
        return @max(0, Parameter.quantize(interval[0]) - Parameter.quantize(point), Parameter.quantize(point) - Parameter.quantize(interval[1]));
    }
    pub fn fitness(self: @This(), parameter: mcg.BiomeParameters.Parameter) i64 {
        return std.math.pow(u64, distance(parameter.continentalness, self.continentalness), 2) +
            std.math.pow(u64, distance(parameter.depth, self.depth), 2) +
            std.math.pow(u64, distance(parameter.erosion, self.erosion), 2) +
            std.math.pow(u64, distance(parameter.humidity, self.humidity), 2) +
            std.math.pow(u64, distance(parameter.temperature, self.temperature), 2) +
            std.math.pow(u64, distance(parameter.weirdness, self.weirdness), 2) +
            std.math.pow(u64, parameter.offset, 2);
    }
};

pub fn at(parameters: mcg.BiomeParameters, point: Point) *const mcg.worldgen.biome {
    var best = point.fitness(parameters.biomes[0].parameters);
    var biome = parameters.biomes[0].biome;

    for (parameters.biomes[1..]) |parameter| {
        const fitness = point.fitness(parameter.parameters);
        if (fitness > best) {
            best = fitness;
            biome = parameter.biome;
        }
    }
    return biome;
}

pub const Position = struct {
    pub const Y = i10;
    pub const XZ = i24;
    x: XZ,
    z: XZ,
    y: Y,

    pub fn init(x: XZ, y: Y, z: XZ) @This() {
        return .{ .x = x, .z = z, .y = y };
    }

    pub fn section(self: @This()) Section {
        return .{
            .x = @intCast(self.x & 0b11),
            .y = @intCast(self.y & 0b11),
            .z = @intCast(self.z & 0b11),
        };
    }

    pub fn chunkSection(self: @This()) Pos.Section {
        return .{ .chunk = .init(@intCast(self.x >> 2), @intCast(self.z >> 2)), .y = @intCast(self.y >> 2) };
    }

    pub const Section = struct {
        x: u2,
        y: u2,
        z: u2,
    };
};

const LCG = struct {
    const MULTIPLIER = 6364136223846793005;
    const INCREMENT = 1442695040888963407;

    seed: u64,

    pub fn fromSeed(seed: u64) @This() {
        var res: u64 = undefined;
        std.crypto.hash.sha2.Sha256.hash(std.mem.asBytes(&std.mem.nativeToBig(u64, seed)), std.mem.asBytes(&res), .{});
        return .{ .seed = std.mem.bigToNative(u64, res) };
    }

    fn mixin(self: *@This(), val: anytype) void {
        self.seed = self.seed * (self.seed *% MULTIPLIER +% INCREMENT) + val;
    }

    fn fiddle(self: *@This(), seed: u64) f64 {
        const res = (@mod(@as(i64, @bitCast(self.seed)) >> 24, 1024) / 1024.0 - 0.5) * 0.9;
        self.mixin(seed);
        return res;
    }

    pub fn getFiddledDistance(self: @This(), pos: Position, delta: NoisePos) f64 {
        var self_mut = self;
        self_mut.mixin(pos.x);
        self_mut.mixin(pos.y);
        self_mut.mixin(pos.z);
        self_mut.mixin(pos.x);
        self_mut.mixin(pos.y);
        self_mut.mixin(pos.z);
        return delta.add(.new(self_mut.fiddle(), self_mut.fiddle(), self_mut.fiddle())).length2(); //vanilla does it the other way araund
    }
    pub fn toBiomePos(self: @This(), pos: Pos.Block) Position {
        const actual = pos.sub(.init(2, 2, 2)) catch unreachable;
        const biome_pos: Position = .init(@intCast(pos.column.x >> 2), @intCast(pos.y >> 2), @intCast(pos.column.z >> 2));
        const delta: NoisePos = .new(
            math.modNorm(actual.column.x, 4),
            math.modNorm(actual.y, 4),
            math.modNorm(actual.column.z, 4),
        );
        var best_pos: Position = undefined;
        var best_fiddled_dist = std.math.inf(f64);

        for (0..0b1000) |offset| {
            const xo: u1 = @intCast(offset >> 2);
            const yo: u1 = @intCast((offset >> 1) & 1);
            const zo: u1 = @intCast(offset & 1);
            const curr: Position = .init(biome_pos.x + xo, biome_pos.y + yo, biome_pos.z + zo);
            const curr_noise = delta.sub(.init(xo, yo, zo));
            const fiddledDistance = self.getFiddledDistance(curr, curr_noise);
            if (best_fiddled_dist > fiddledDistance) {
                best_pos = curr;
                best_fiddled_dist = fiddledDistance;
            }
        }

        return best_pos;
    }
};
