const mcg = @import("mc-generated");
const zigwg = @import("zigwg");
const rng = @import("rng.zig");
const meta = @import("meta.zig");
const mf64 = @import("zlm").as(f64);
const math = @import("math.zig");
const Pos = @import("position.zig");
const block = @import("block.zig");
const nbt = @import("nbt");
const std = @import("std");
const noises = @import("noise.zig");
const Id = []const u8;
const density_function = @import("density_function.zig");
const PalettedContainer = @import("paletted_container.zig").PalettedContainer;

pub fn gen(comptime settings: mcg.worldgen.noise_settings, seed: u64) [@divExact(settings.noise.height, 16)]PalettedContainer(.block) {
    var chunk: [@divExact(settings.noise.height, 16)]PalettedContainer(.block) = @splat(.{ .single = @import("block.zig").instance(&mcg.Block.@"minecraft:air", .{}) });
    var random = if (settings.legacy_random_source) rng.Rng(rng.Legacy).init(.init(seed)) else rng.Rng(rng.Xoroshiro).init(.fromSeed(seed));
    const rng_factory = random.forkPositional();
    const chunk_pos: Pos.Chunk = .init(0, 0);

    const firstNoiseXBlock = chunk_pos.x;
    const firstNoiseZBlock = chunk_pos.z;
    const cellWidth: u5 = comptime @intCast(quartToBlock(settings.noise.size_horizontal));
    const cellHeight: u5 = comptime @intCast(quartToBlock(settings.noise.size_vertical));
    const cellCountXZ = 16 / cellWidth;
    const cellCountY = @divFloor(settings.noise.height, cellHeight);
    const cellNoiseMinY = @divFloor(settings.noise.min_y, cellHeight);
    _ = cellNoiseMinY; // autofix
    const firstCellX = @divFloor(firstNoiseXBlock, cellWidth);
    _ = firstCellX; // autofix
    const firstCellZ = @divFloor(firstNoiseZBlock, cellWidth);
    _ = firstCellZ; // autofix
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

    var blended_random = if (settings.legacy_random_source) rng.Rng(rng.Legacy).init(.init(seed)) else rng_factory.fromHashOf("minecraft:terrain");
    const rng_type = if (settings.legacy_random_source) rng.Legacy else rng.Xoroshiro;
    const noise_holder = density_function.initNoiseHolder(mcg.worldgen.noise, rng_type, rng_factory);
    const blended_noise = noises.Blended.create(rng_type, &blended_random);
    var interpolators: [10]density_function.Interpolator(cellWidth, cellHeight, @intCast(settings.noise.height)) = @splat(.{});
    var density_fs: [10]mcg.worldgen.density_function.DensityF = undefined;
    var count: usize = 0;
    const context = .{
        .settings = settings,
        .noise_holder = noise_holder,
        .blended_noise = blended_noise,
        .interpolator = .{ .interpolators = &interpolators, .density_functions = &density_fs, .count = &count },
        .chunk_pos = chunk_pos,
        .min_y = settings.noise.min_y,
        .max_y = settings.noise.min_y + settings.noise.height,
    };

    for (0..cellCountXZ) |cell_x| for (0..cellCountXZ) |cell_z| for (0..cellCountY) |cell_y_from_top| {
        const cell_y = cellCountY - 1 - cell_y_from_top;
        for (0..cellHeight) |inner_cell_y_from_top| {
            const inner_cell_y = cellHeight - 1 - inner_cell_y_from_top;
            const curr_y = settings.noise.min_y + @as(Pos.Y, @intCast(cell_y * cellHeight + inner_cell_y));
            const section_y: Pos.Chunk.Offset = @intCast(curr_y & 0xf);
            const section = &chunk[@intCast((curr_y - settings.noise.min_y) >> 4)];

            const section_pos = chunk_pos.section(@intCast(curr_y >> 4));
            for (0..cellWidth) |inner_cell_x| {
                const chunk_x: Pos.Chunk.Offset = @intCast(cell_x * cellWidth + inner_cell_x);
                for (0..cellWidth) |inner_cell_z| {
                    const chunk_z: Pos.Chunk.Offset = @intCast(cell_z * cellWidth + inner_cell_z);
                    const inner_pos: Pos.Section.Block = .init(chunk_x, section_y, chunk_z);
                    const final_density = density_function.evalDensityFunction(settings.noise_router.final_density, section_pos.block(inner_pos), context);
                    if (section_pos.block(inner_pos) == Pos.Block.init(0, 0, 0)) {
                        std.debug.print("final_density: {d}\n", .{final_density});
                    }
                    if (0.0 < final_density) {
                        section.set(inner_pos, block.instance(&mcg.Block.@"minecraft:stone", .{}));
                    }
                }
            }
        }
    };

    return chunk;
}
fn quartToBlock(val: i32) i32 {
    return val << 2;
}
fn blockToQuart(val: i32) i32 {
    return val >> 2;
}
