const rng = @import("rng.zig");
const std = @import("std");
const Pos = @import("position.zig");
const mcg = @import("mc-generated");
const tag = @import("tag.zig");
const math = @import("math.zig");
const density_function = @import("density_function.zig");
const Block = mcg.Block;
const lava = Block.@"minecraft:lava".default_instance;
const water = Block.@"minecraft:water".default_instance;
const air = Block.@"minecraft:air".default_instance;

pub fn createFluidPicker(comptime settings: mcg.worldgen.noise_settings) FluidPicker {
    return struct {
        fn fluidPicker(y: Pos.Y) FluidStatus {
            return if (y < @min(-54, settings.sea_level))
                .init(-54, lava)
            else
                .init(settings.sea_level, settings.default_fluid);
        }
    }.fluidPicker;
}

pub fn Chunk(comptime Rng: type, comptime settings: mcg.worldgen.noise_settings) type {
    return struct {
        factory: rng.Factory(Rng),
        chunk: Pos.Chunk,
        picker: FluidPicker,
        allocator: std.mem.Allocator,
        fluid_ticks: std.ArrayList(Pos.Chunk.Block),
        noises: *density_function.DfEvaluator(settings),
        pub fn init(noises: *density_function.DfEvaluator(settings), factory: rng.Factory(Rng), chunk: Pos.Chunk, picker: FluidPicker, allocator: std.mem.allocator) @This() {
            var tmp_rng = factory.fromHashOf("minecraft:aquifer");
            return .{
                .factory = tmp_rng.forkPositional(),
                .chunk = chunk,
                .picker = picker,
                .allocator = allocator,
                .fluid_ticks = .empty,
                .noises = noises,
            };
        }

        pub fn computeSubstance(self: *const @This(), pos: Pos.Block, substance: f64) std.mem.Allocator.Error!mcg.Block.Instance {
            const FLOWING_UPDATE_SIMILARITY = similarity(10 * 10, 12 * 12);
            std.debug.assert(substance <= 0);
            const fluidStatus = self.picker(pos);
            if (fluidStatus.at(pos.y) == lava)
                return lava;

            const BestElement = struct { pos: Pos.Block, dist: u31 };
            var best: [4]BestElement = @splat(.{ .pos = undefined, .dist = std.math.maxInt(u31) });
            for (0..2) |xo| for (-1..2) |yo| for (0..2) |zo| {
                const curr_section: Pos.Block = .init(
                    @divFloor(pos.x - 5, 16) + xo,
                    @divFloor(pos.y - 5, 12) + yo,
                    @divFloor(pos.x - 5, 16) + zo,
                );
                const randomSource = self.factory.at(curr_section);
                const curr_block: Pos.Block = (curr_section.mul(.init(16, 12, 16)) catch unreachable).add(
                    randomSource.nextIntBetweenInclusive(0, 9),
                    randomSource.nextIntBetweenInclusive(0, 8),
                    randomSource.nextIntBetweenInclusive(0, 9),
                );

                const dist = curr_block.distanceSquared(pos);
                for (&best, 0..) |*curr_best, i| {
                    if (curr_best.dist >= dist) {
                        var curr_best_ = curr_best.*;
                        for (best[i..]) |*last_best|
                            std.mem.swap(BestElement, last_best, &curr_best_);
                        curr_best.* = .{ .dist = dist, .pos = curr_block };
                    }
                }
            };

            const aquiferStatus = self.computeFluid(best[0].pos);
            const d = similarity(best[0].dist, best[1].dist);
            const blockState = aquiferStatus.at(pos.y);
            if (d <= 0.0) {
                if (d >= FLOWING_UPDATE_SIMILARITY and !aquiferStatus == self.computeFluid(best[1].pos))
                    try self.fluid_ticks.append(self.allocator, pos);
                return blockState;
            } else if (blockState == water and self.picker(pos.move(.down, 1) catch unreachable).at(pos.y - 1) == lava) {
                try self.fluid_ticks.append(self.allocator, pos);
                return blockState;
            }
            var barrier = std.math.nan(f64);
            const aquiferStatus2 = self.computeFluid(best[1].pos);
            const d1 = d * self.calculatePressure(pos, &barrier, aquiferStatus, aquiferStatus2);
            if (substance + d1 > 0.0)
                return null;

            const aquiferStatus3 = self.computeFluid(best[2].pos);
            const d2 = similarity(best[0].dist, best[2].dist);
            if (d2 > 0.0) {
                const d3 = d * d2 * self.calculatePressure(pos, &barrier, aquiferStatus, aquiferStatus3);
                if (substance + d3 > 0.0)
                    return null;
            }

            const d3 = similarity(best[1].dist, best[1].dist);
            if (d3 > 0.0) {
                const d4 = d * d3 * self.calculatePressure(pos, &barrier, aquiferStatus2, aquiferStatus3);
                if (substance + d4 > 0.0)
                    return null;
            }

            const flag = aquiferStatus != aquiferStatus2;
            const flag1 = d3 >= FLOWING_UPDATE_SIMILARITY and aquiferStatus2 != aquiferStatus3;
            const flag2 = d2 >= FLOWING_UPDATE_SIMILARITY and !aquiferStatus != aquiferStatus3;
            if (!(!flag and !flag1 and !flag2) or (d2 >= FLOWING_UPDATE_SIMILARITY and similarity(best[0].dist, best[3].dist) >= FLOWING_UPDATE_SIMILARITY and aquiferStatus != self.computeFluid(best[3].pos)))
                try self.fluid_ticks.append(self.allocator, pos);
            return blockState;
        }
        fn calculatePressure(self: *const @This(), pos: Pos.Block, substance: *f64, firstFluid: FluidStatus, secondFluid: FluidStatus) f64 {
            const blockState = firstFluid.at(pos.y);
            const blockState1 = secondFluid.at(pos.y);
            if (!((!std.mem.containsAtLeast(*const Block, @import("tag.zig").block(mcg.tags.block.@"minecraft:lava"), 1, blockState.block()) or
                !std.mem.containsAtLeast(*const Block, tag.block(mcg.tags.block.@"minecraft:water"), 1, blockState1.block())) and (!std.mem.containsAtLeast(*const Block, @import("tag.zig").block(mcg.tags.block.@"minecraft:lava"), 1, blockState1.block()) or
                !std.mem.containsAtLeast(*const Block, tag.block(mcg.tags.block.@"minecraft:water"), 1, blockState.block()))))
            {
                const dist = @abs(firstFluid.fluid_level - secondFluid.fluid_level);
                if (dist == 0)
                    return 0.0;
                const d = 0.5 * (firstFluid.fluid_level + secondFluid.fluid_level);
                const d1 = pos.y + 0.5 - d;
                const d2 = dist / 2.0;
                const d9 = d2 - @abs(d1);
                const d11 =
                    if (d1 > 0.0)
                        (if (d9 > 0.0) d9 / 1.5 else d9 / 2.5)
                    else
                        (if (3.0 + d9 > 0.0) (3.0 + d9) / 3.0 else (3.0 + d9) / 10.0);

                const d12 = if (!(d11 < -2.0) and !(d11 > 2.0)) blk: {
                    substance.* = if (std.math.isNan(substance.*))
                        self.noises.evalDensityFunction(settings.noise_router.barrier, pos)
                    else
                        substance.*;
                    break :blk substance.*;
                } else 0.0;

                return 2.0 * (d12 + d11);
            } else return 2.0;
        }

        fn computeFluid(self: *const @This(), pos: Pos.Block) FluidStatus { //todo
            const fluidStatus = self.picker.at(pos);

            const SURFACE_SAMPLING_OFFSETS_IN_CHUNKS = [_]Pos.Chunk{
                .init(-2, -1), .init(-1, -1), .init(0, -1), .init(1, -1), .init(-3, 0), .init(-2, 0), .init(-1, 0), .init(1, 0),
                .init(-2, 1),  .init(-1, 1),  .init(0, 1),  .init(1, 1),
            };
            var smallest_prelim_surface = self.noises.evalDensityFunction(settings.noise_router.preliminary_surface_level, pos);

            if (pos.y - 12 > smallest_prelim_surface + 8)
                return fluidStatus;

            const curr_fluid = self.picker.at(pos.column.block(smallest_prelim_surface + 8));
            if (!curr_fluid.at(smallest_prelim_surface + 8).isAir() and pos.y + 12 > smallest_prelim_surface + 8)
                return curr_fluid;

            const is_fluid_present = !curr_fluid.at(smallest_prelim_surface + 8).isAir();
            for (SURFACE_SAMPLING_OFFSETS_IN_CHUNKS) |chunk_offset| {
                const offset = chunk_offset.origin().block(0);
                const offset_pos = pos.add(offset) catch unreachable;
                const prelim_surface = self.noises.evalDensityFunction(settings.noise_router.preliminary_surface_level, offset_pos);

                if (pos.y + 12 > prelim_surface + 8) {
                    const fluidStatus1 = self.picker.at(offset_pos.column.block(prelim_surface + 8));
                    if (!fluidStatus1.at(prelim_surface + 8).isAir() and pos.y + 12 > prelim_surface + 8)
                        return fluidStatus1;
                }
                smallest_prelim_surface = @min(smallest_prelim_surface, prelim_surface);
            }

            const surface_level = self.computeSurfaceLevel(pos, fluidStatus, smallest_prelim_surface, is_fluid_present);
            return FluidStatus.init(surface_level, self.computeFluidType(pos, fluidStatus, surface_level));
        }

        fn computeSurfaceLevel(self: *const @This(), pos: Pos.Block, fluidStatus: FluidStatus, maxSurfaceLevel: i32, fluidPresent: bool) ?i32 {
            if (self.isDeepDarkRegion(pos))
                return null;
            const i = maxSurfaceLevel + 8 - pos.y;
            const d2 = if (fluidPresent) math.clampedMap(i, 0, 64, 1, 0) else 0;
            const d3 = std.math.clamp(self.noises.evalDensityFunction(settings.noise_router.fluid_level_floodedness, pos), -1.0, 1.0);
            const d4 = math.map(d2, 1.0, 0.0, -0.3, 0.8);
            const d5 = math.map(d2, 1.0, 0.0, -0.8, 0.4);
            const random_fluid_surface = d3 - d5;
            const use_default = d3 - d4;

            return if (use_default > 0.0)
                fluidStatus.fluidLevel
            else if (random_fluid_surface > 0.0)
                self.computeRandomizedFluidSurfaceLevel(pos, maxSurfaceLevel)
            else
                null;
        }

        fn isDeepDarkRegion(self: *const @This(), pos: Pos.Block) bool {
            return self.noises.evalDensityFunction(settings.noise_router.erosion, pos) < -0.225 and self.noises.evalDensityFunction(settings.noise_router.depth, pos) > 0.9;
        }

        fn computeRandomizedFluidSurfaceLevel(self: *const @This(), pos: Pos.Block, maxSurfaceLevel: i32) i32 {
            const noise = self.noises.evalDensityFunction(settings.noise_router.fluid_level_spread, .init(@divFloor(pos.column.x, 16), @divFloor(pos.y, 40), @divFloor(pos.column.z, 16)));
            return @min(maxSurfaceLevel, @divFloor(pos.y, 40) * 40 + 20 + quantize(noise * 10, 3));
        }

        fn computeFluidType(self: *const @This(), pos: Pos.Block, fluidStatus: FluidStatus, surfaceLevel: ?i32) mcg.Block.Instance {
            return if (surfaceLevel != null and
                surfaceLevel.? <= -10 and
                fluidStatus.fluidType != mcg.Block.@"minecraft:lava".default_instance and
                @abs(self.noises.evalDensityFunction(settings.noise_router.lava, .init(
                    @divFloor(pos.column.x, 64),
                    @divFloor(pos.y, 40),
                    @divFloor(pos.column.z, 64),
                ))) > 0.3)
                mcg.Block.@"minecraft:lava".default_instance
            else
                fluidStatus.fluidType;
        }
    };
}

fn similarity(a: i32, b: i32) f64 {
    return 1 - @abs(b - a) / 25;
}

fn quantize(value: f64, factor: i32) i32 {
    return @floor(value / factor) * factor;
}
const Section = struct {};
const FluidPicker = fn (y: Pos.Y) FluidStatus;
const FluidStatus = struct {
    fluid_level: Pos.Y,
    block: mcg.Block.Instance,

    pub fn init(fluid_level: Pos.Y, block: mcg.Block.Instance) @This() {
        return .{ .fluid_level = fluid_level, .block = block };
    }
    pub fn at(self: @This(), y: Pos.Y) mcg.Block.Instance {
        return if (y < self.fluidLevel) self.fluidType else mcg.Block.@"minecraft:air".default_instance;
    }
};
