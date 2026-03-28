const mcg = @import("mc-generated");
const zigwg = @import("zigwg");
const rng = @import("rng.zig");
const meta = @import("meta.zig");
const mf64 = @import("zlm").as(f64);
const math = @import("math.zig");
const Pos = @import("position.zig");

const LegacyRng = @import("LegacyRng.zig");
const XoroshiroRng = @import("XoroshiroRng.zig");
const std = @import("std");
const noises = @import("noise.zig");
const Id = []const u8;
const density_function = @import("density_function.zig");

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

pub fn main() !void {
    const seed = 1;
    const settings = mcg.worldgen.noise_settings.@"minecraft:overworld";
    var random = if (settings.legacy_random_source) rng.Rng(LegacyRng).init(.init(seed)) else rng.Rng(XoroshiroRng).init(.fromSeed(seed));
    const rng_factory = random.forkPositional();
    const chunk_pos: Pos.Chunk = .init(0, 0);

    const firstNoiseXBlock = chunk_pos.x;
    const firstNoiseZBlock = chunk_pos.z;
    const cellWidth: u5 = comptime @intCast(quartToBlock(settings.noise.size_horizontal));
    const cellHeight: u5 = comptime @intCast(quartToBlock(settings.noise.size_vertical));
    const cellCountXZ = 16 / cellWidth;
    const cellCountY = @divFloor(settings.noise.height, cellHeight);
    _ = cellCountY; // autofix
    const cellNoiseMinY = @divFloor(settings.noise.min_y, cellHeight);
    _ = cellNoiseMinY; // autofix
    const firstCellX = @divFloor(firstNoiseXBlock, cellWidth);
    _ = firstCellX; // autofix
    const firstCellZ = @divFloor(firstNoiseZBlock, cellWidth);
    _ = firstCellZ; // autofix
    const interpolators = &.{};
    _ = interpolators; // autofix
    const cellCaches = &.{};
    _ = cellCaches; // autofix
    const firstNoiseX = blockToQuart(firstNoiseXBlock);
    _ = firstNoiseX; // autofix
    const firstNoiseZ = blockToQuart(firstNoiseZBlock);
    _ = firstNoiseZ; // autofix
    const noiseSizeXZ = blockToQuart(cellCountXZ * cellWidth);
    _ = noiseSizeXZ; // autofix
    // const blender: [noiseSizeXZ + 1][noiseSizeXZ + 1]f64 = undefined;
    // for (0..noiseSizeXZ) |noisex| {
    //     const blockPosCoord = quartToBlock(firstNoiseX + @as(i32, @intCast(noisex)));
    //     for (0..noiseSizeXZ) |noisez| {
    //         const blockPosCoord1 = quartToBlock(firstNoiseZ + @as(i32, @intCast(noisez)));
    //         _ = blockPosCoord;
    //         _ = blockPosCoord1;
    //         const blendingOutput = 1;
    //         blender[noisex][noisez] = blendingOutput;
    //     }
    // }

    var blended_random = if (settings.legacy_random_source) rng.Rng(LegacyRng).init(.init(seed)) else rng_factory.fromHashOf("minecraft:terrain");
    const rng_type = if (settings.legacy_random_source) LegacyRng else XoroshiroRng;
    const noise_holder = density_function.initNoiseHolder(mcg.worldgen.noise, rng_type, rng_factory);
    const blended_noise = noises.Blended.create(rng_type, &blended_random);
    const context = .{
        .settings = settings,
        .noise_holder = noise_holder,
        .blended_noise = blended_noise,
        .interpolator = density_function.Interpolator(cellWidth, cellHeight, @intCast(settings.noise.height)){},
        .chunk_pos = chunk_pos,
        .min_y = settings.noise.min_y,
        .max_y = settings.noise.min_y + settings.noise.height,
    };

    _ = density_function.evalDensityFunction(settings.noise_router.final_density, chunk_pos.block(.init(0, context.max_y - 1, 0)), context);
    const val = density_function.evalDensityFunction(settings.noise_router.final_density, chunk_pos.block(.init(0, 0, 0)), context);
    std.debug.print("final_density: {d}\n", .{val});
}

fn quartToBlock(val: i32) i32 {
    return val << 2;
}
fn blockToQuart(val: i32) i32 {
    return val >> 2;
}
