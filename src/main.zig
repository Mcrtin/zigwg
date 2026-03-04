const mcg = @import("mc-generated");
const zigwg = @import("zigwg");
const rng = @import("rng.zig");
const meta = @import("meta.zig");
const mf64 = @import("zlm").as(f64);
const math = @import("math.zig");

const LegacyRng = @import("LegacyRng.zig");
const XoroshiroRng = @import("XoroshiroRng.zig");
const std = @import("std");
const noises = @import("noise.zig");
const Id = []const u8;

pub const ParameterPoint = struct {
    temperature: Parameter,
    humidity: Parameter,
    continentalness: Parameter,
    erosion: Parameter,
    depth: Parameter,
    weirdness: Parameter,
    offset: i64,
    pub fn from(comptime val: anytype) @This() {
        return .{
            .temperature = .from(val.temperature),
            .humidity = .from(val.humidity),
            .continentalness = .from(val.continentalness),
            .erosion = .from(val.erosion),
            .depth = .from(val.depth),
            .weirdness = .from(val.weirdness),
            .offset = Parameter.quantize(val.offset),
        };
    }
};
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

pub const Position = struct {
    x: i32,
    y: i32,
    z: i32,
};
pub const NoisePosition = mf64.Vec3;
pub const NoiseRouter = struct {
    barrier: ?*const fn (pos: Position, ctx: anytype) f64,
    continents: ?*const fn (pos: Position, ctx: anytype) f64,
    depth: ?*const fn (pos: Position, ctx: anytype) f64,
    erosion: ?*const fn (pos: Position, ctx: anytype) f64,
    final_density: ?*const fn (pos: Position, ctx: anytype) f64,
    fluid_level_floodedness: ?*const fn (pos: Position, ctx: anytype) f64,
    fluid_level_spread: ?*const fn (pos: Position, ctx: anytype) f64,
    lava: ?*const fn (pos: Position, ctx: anytype) f64,
    preliminary_surface_level: ?*const fn (pos: Position, ctx: anytype) f64,
    ridges: ?*const fn (pos: Position, ctx: anytype) f64,
    temperature: ?*const fn (pos: Position, ctx: anytype) f64,
    vegetation: ?*const fn (pos: Position, ctx: anytype) f64,
    vein_gap: ?*const fn (pos: Position, ctx: anytype) f64,
    vein_ridged: ?*const fn (pos: Position, ctx: anytype) f64,
    vein_toggle: ?*const fn (pos: Position, ctx: anytype) f64,
    fn evalSpline(val: anytype, pos: Position, ctx: anytype) f32 {
        if (@TypeOf(val) == comptime_float) return val;
        const points = val.points;

        const location: f32 = @floatCast(evalDf(val.coordinate, pos, ctx));

        inline for (0..points.len) |idx| {
            const hi = points[idx];
            if (location < hi.location) {
                if (idx == 0) {
                    const value = evalSpline(hi.value, pos, ctx);
                    return if (hi.derivative == 0.0)
                        value
                    else
                        value + hi.derivative * (location - hi.location);
                }
                const lo = points[idx - 1];
                const loc_grad = (location - lo.location) / (hi.location - lo.location);

                const lo_val = evalSpline(lo.value, pos, ctx);
                const hi_val = evalSpline(hi.value, pos, ctx);
                const start = lo.derivative * (hi.location - lo.location) - (hi_val - lo_val);
                const end = -hi.derivative * (hi.location - lo.location) + (hi_val - lo_val);
                return math.lerpf(loc_grad, lo_val, hi_val) + loc_grad * (1.0 - loc_grad) * math.lerpf(loc_grad, start, end);
            }
        }
        const lo = points[points.len - 1];
        const value = evalSpline(lo.value, pos, ctx);
        return if (lo.derivative == 0.0)
            value
        else
            value + lo.derivative * (location - lo.location);
    }

    fn evalNoise(comptime noise_name: Id, pos: NoisePosition, ctx: anytype) f64 {
        if (comptime !std.mem.startsWith(u8, noise_name, "minecraft:")) @compileError("unsupported string " ++ noise_name);
        const noise = getNoise(ctx.noise_holder, noise_name["minecraft:".len..]);
        return noise.getValue(pos);
    }

    fn evalDf(comptime val: anytype, pos: Position, ctx: anytype) f64 {
        const T = @TypeOf(val);
        if (T == comptime_float) return val;
        if (T == comptime_int) return @intFromFloat(val);
        if (T == Id) return evalNoise(val, .from(pos), ctx);
        switch (@typeInfo(T)) {
            .pointer => |p| {
                if (@typeInfo(p.child).array.child != u8) @compileError("unsupported val ptr type " ++ @typeName(@typeInfo(p.child).array.child));
                // mcg.Worldgen.DensityFunction
                const res = comptime meta.getFromRegistry(mcg.@"worldgen/".@"density_function/", val);

                return evalDf(res, pos, ctx);
            },
            .@"struct" => {
                const fn_type = val.type;
                if (comptime eql(fn_type, "minecraft:interpolated")) {
                    return evalDf(val.argument, pos, ctx);
                } else if (comptime eql(fn_type, "minecraft:cache_2d")) {
                    return evalDf(val.argument, pos, ctx);
                } else if (comptime eql(fn_type, "minecraft:cache_once")) {
                    return evalDf(val.argument, pos, ctx);
                } else if (comptime eql(fn_type, "minecraft:flat_cache")) {
                    return evalDf(val.argument, pos, ctx);
                } else if (comptime eql(fn_type, "minecraft:blend_density")) {
                    return evalDf(val.argument, pos, ctx);
                } else if (comptime eql(fn_type, "minecraft:blend_alpha")) {
                    return 1.0;
                } else if (comptime eql(fn_type, "minecraft:blend_offset")) {
                    return 0.0;
                } else if (comptime eql(fn_type, "minecraft:old_blended_noise")) {
                    return ctx.blended_noise.compute(.new(@floatFromInt(pos.x), @floatFromInt(pos.y), @floatFromInt(pos.z)), val.xz_scale, val.y_scale, val.xz_factor, val.y_factor, val.smear_scale_multiplier);
                } else if (comptime eql(fn_type, "minecraft:range_choice")) {
                    const cond = evalDf(val.input, pos, ctx);
                    return if (val.min_inclusive <= cond and cond < val.max_exclusive)
                        evalDf(val.when_in_range, pos, ctx)
                    else
                        evalDf(val.when_out_of_range, pos, ctx);
                } else if (comptime eql(fn_type, "minecraft:clamp")) {
                    return std.math.clamp(evalDf(val.input, pos, ctx), val.min, val.max);
                } else if (comptime eql(fn_type, "minecraft:noise")) {
                    var noise_pos: NoisePosition = .new(@floatFromInt(pos.x), @floatFromInt(pos.y), @floatFromInt(pos.z));
                    noise_pos.x *= val.xz_scale;
                    noise_pos.y *= val.y_scale;
                    noise_pos.z *= val.xz_scale;
                    return evalNoise(val.noise, noise_pos, ctx);
                } else if (comptime eql(fn_type, "minecraft:add")) {
                    return evalDf(val.argument1, pos, ctx) + evalDf(val.argument2, pos, ctx);
                } else if (comptime eql(fn_type, "minecraft:mul")) {
                    return evalDf(val.argument1, pos, ctx) * evalDf(val.argument2, pos, ctx);
                } else if (comptime eql(fn_type, "minecraft:min")) {
                    return @min(evalDf(val.argument1, pos, ctx), evalDf(val.argument2, pos, ctx));
                } else if (comptime eql(fn_type, "minecraft:max")) {
                    return @max(evalDf(val.argument1, pos, ctx), evalDf(val.argument2, pos, ctx));
                } else if (comptime eql(fn_type, "minecraft:abs")) {
                    return @abs(evalDf(val.argument, pos, ctx));
                } else if (comptime eql(fn_type, "minecraft:square")) {
                    const res = evalDf(val.argument, pos, ctx);
                    return res * res;
                } else if (comptime eql(fn_type, "minecraft:cube")) {
                    const res = evalDf(val.argument, pos, ctx);
                    return res * res * res;
                } else if (comptime eql(fn_type, "minecraft:half_negative")) {
                    const res = evalDf(val.argument, pos, ctx);
                    return if (res > 0.0) res else res / 2;
                } else if (comptime eql(fn_type, "minecraft:quarter_negative")) {
                    const res = evalDf(val.argument, pos, ctx);
                    return if (res > 0.0) res else res / 4;
                } else if (comptime eql(fn_type, "minecraft:squeeze")) {
                    const res = std.math.clamp(evalDf(val.argument, pos, ctx), -1.0, 1.0);
                    return res / 2 - res * res * res / 24;
                } else if (comptime eql(fn_type, "minecraft:invert")) {
                    return -evalDf(val.argument, pos, ctx);
                } else if (comptime eql(fn_type, "minecraft:y_clamped_gradient")) {
                    return math.clampedMap(@floatFromInt(pos.y), @floatFromInt(val.from_y), @floatFromInt(val.to_y), val.from_value, val.to_value);
                } else if (comptime eql(fn_type, "minecraft:weird_scaled_sampler")) {
                    const value = evalDf(val.input, pos, ctx);
                    const mapped: f64 = if (comptime eql(val.rarity_value_mapper, "type_1"))
                        (if (value < -0.75)
                            0.5
                        else if (value < -0.5)
                            0.75
                        else if (value < 0.5)
                            1.0
                        else if (value < 0.75)
                            2.0
                        else
                            3.0)
                    else if (comptime eql(val.rarity_value_mapper, "type_2")) (if (value < -0.5)
                        0.75
                    else if (value < 0.0)
                        1.0
                    else if (value < 0.5)
                        1.5
                    else
                        2.0) else @compileError("unsupported rarity value mapper " ++ val.rarity_value_mapper);
                    var noise_pos: NoisePosition = .new(@floatFromInt(pos.x), @floatFromInt(pos.y), @floatFromInt(pos.z));
                    noise_pos.x /= mapped;
                    noise_pos.y /= mapped;
                    noise_pos.z /= mapped;
                    return mapped * @abs(evalNoise(val.noise, noise_pos, ctx));
                } else if (comptime eql(fn_type, "minecraft:shifted_noise")) {
                    var noise_pos: NoisePosition = .new(@floatFromInt(pos.x), @floatFromInt(pos.y), @floatFromInt(pos.z));
                    noise_pos.x *= val.xz_scale;
                    noise_pos.y *= val.y_scale;
                    noise_pos.z *= val.xz_scale;

                    noise_pos.x += evalDf(val.shift_x, pos, ctx);
                    noise_pos.y += evalDf(val.shift_x, pos, ctx);
                    noise_pos.z += evalDf(val.shift_x, pos, ctx);

                    return evalNoise(val.noise, noise_pos, ctx);
                } else if (comptime eql(fn_type, "minecraft:find_top_surface")) {
                    const min = evalDf(val.lower_bound, pos, ctx);
                    const max = evalDf(val.upper_bound, pos, ctx);
                    var y: i32 = @intFromFloat(max);
                    while (y >= min) : (y -= val.cell_height) {
                        var curr_pos = pos;
                        curr_pos.y = y;
                        const res = evalDf(val.density, curr_pos, ctx);
                        if (res > 0.390625) return y;
                    }
                    return @floatFromInt(std.math.maxInt(i32));
                } else if (comptime eql(fn_type, "minecraft:shift_a")) {
                    return evalNoise(val.argument, .{ .x = @floatFromInt(pos.x), .y = 0, .z = @floatFromInt(pos.z) }, ctx);
                } else if (comptime eql(fn_type, "minecraft:shift_b")) {
                    return evalNoise(val.argument, .{ .x = @floatFromInt(pos.z), .y = @floatFromInt(pos.x), .z = 0 }, ctx);
                } else if (comptime eql(fn_type, "minecraft:spline")) {
                    return @floatCast(evalSpline(val.spline, pos, ctx));
                } else @compileError("unsupported fn type " ++ fn_type);
            },
            else => @compileError("unsupported val type " ++ @typeName(T)),
        }
    }

    fn eql(comptime a: []const u8, comptime b: []const u8) bool {
        return comptime std.mem.eql(u8, a, b);
    }
    fn toFn(comptime val: anytype) ?*const fn (pos: Position, ctx: anytype) f64 {
        if (@TypeOf(val) == comptime_float) {
            std.debug.assert(val == 0);
            return null;
        }
        const S = struct {
            pub fn f(pos: Position, ctx: anytype) f64 {
                return evalDf(val, pos, ctx);
            }
        };

        return &S.f;
    }

    pub fn from(comptime val: anytype) @This() {
        return .{
            .barrier = toFn(val.barrier),
            .continents = toFn(val.continents),
            .depth = toFn(val.depth),
            .erosion = toFn(val.erosion),
            .final_density = toFn(val.final_density),
            .fluid_level_floodedness = toFn(val.fluid_level_floodedness),
            .fluid_level_spread = toFn(val.fluid_level_spread),
            .lava = toFn(val.lava),
            .preliminary_surface_level = toFn(val.preliminary_surface_level),
            .ridges = toFn(val.ridges),
            .temperature = toFn(val.temperature),
            .vegetation = toFn(val.vegetation),
            .vein_gap = toFn(val.vein_gap),
            .vein_ridged = toFn(val.vein_ridged),
            .vein_toggle = toFn(val.vein_toggle),
        };
    }
};

pub const NoiseSettings = struct {
    aquifers_enabled: bool,
    default_block: struct {
        Name: Id,
        //TODO: Block from data
    },
    default_fluid: struct {
        Name: Id,
    },
    disable_mob_generation: bool,
    legacy_random_source: bool,
    noise: struct {
        height: u32,
        min_y: i32,
        size_horizontal: u32,
        size_vertical: u32,
    },
    noise_router: NoiseRouter,
    ore_veins_enabled: bool,
    sea_level: i32,
    spawn_target: []ParameterPoint,
    // surface_rule: struct {},
    pub fn from(comptime val: anytype) @This() {
        return .{
            .aquifers_enabled = val.aquifers_enabled,
            .default_block = .{ .Name = val.default_block.Name },
            .default_fluid = .{ .Name = val.default_block.Name },
            .disable_mob_generation = val.disable_mob_generation,
            .legacy_random_source = val.legacy_random_source,
            .noise = .{
                .height = val.noise.height,
                .min_y = val.noise.min_y,
                .size_horizontal = val.noise.size_horizontal,
                .size_vertical = val.noise.size_vertical,
            },
            .ore_veins_enabled = val.ore_veins_enabled,
            .sea_level = val.sea_level,
            // .spawn_target = val.spawn_target,
            .noise_router = .from(val.noise_router),
            .spawn_target = blk: {
                var res: [val.spawn_target.len]ParameterPoint = undefined;
                for (&res, val.spawn_target) |*item, target| item.* = .from(target);
                break :blk &res;
            },
        };
    }
};
const NoiseHolder = makeNoiseHolderType(mcg.@"worldgen/".@"noise/");
fn makeNoiseHolderType(comptime noise_data: type) type {
    const decls = @typeInfo(noise_data).@"struct".decls;
    var out_list: [decls.len]std.builtin.Type.StructField = undefined;
    inline for (decls, &out_list) |curr, *out| {
        const T = noises.NormalNoise(@field(noise_data, curr.name).amplitudes.len);
        out.* = .{
            .name = curr.name,
            .type = T,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(T),
        };
    }

    return @Type(.{
        .@"struct" = .{
            .is_tuple = false,
            .layout = .auto,
            .decls = &.{},
            .fields = &out_list,
        },
    });
}

pub fn initNoiseHolder(noise_data: type, rng_type: type, rng_factory: rng.Factory(rng_type)) NoiseHolder {
    var res: NoiseHolder = undefined;
    // const decls = @typeInfo(noise_data).@"struct".decls;
    inline for (@typeInfo(@TypeOf(res)).@"struct".fields) |curr| {
        var random = rng_factory.fromHashOf("minecraft:" ++ curr.name);
        @field(res, curr.name) = .init(rng_type, &random, meta.fromData(noises.NoiseData, @field(noise_data, curr.name)), true);
    }
    return res;
}
pub fn getNoise(noise_holder: anytype, comptime name: []const u8) noises.NormalNoise(@TypeOf(@field(noise_holder, name)).octaves) {
    return @field(noise_holder, name);
}

pub fn main() !void {
    const seed = 1;
    const settings = NoiseSettings.from(mcg.@"worldgen/".@"noise_settings/".overworld);
    var random = if (settings.legacy_random_source) rng.Rng(LegacyRng).init(.init(seed)) else rng.Rng(XoroshiroRng).init(.fromSeed(seed));
    const rng_factory = random.forkPositional();
    const x: i32 = 0;
    const z: i32 = 0;

    const firstNoiseXBlock = x;
    const firstNoiseZBlock = z;
    const cellWidth: u31 = @intCast(quartToBlock(settings.noise.size_horizontal));
    const cellHeight: u31 = @intCast(quartToBlock(settings.noise.size_vertical));
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
    const blended_noise = noises.Blended.create(if (settings.legacy_random_source) LegacyRng else XoroshiroRng, &blended_random);
    const rng_type = if (settings.legacy_random_source) LegacyRng else XoroshiroRng;
    const noise_holder = initNoiseHolder(mcg.@"worldgen/".@"noise/", rng_type, rng_factory);

    const val = settings.noise_router.final_density.?.*(.{ .x = x * 16, .y = 0, .z = z * 16 }, .{ .settings = settings, .noise_holder = noise_holder, .blended_noise = blended_noise });
    // Prints to stderr, ignoring potential errors.
    std.debug.print("All your {any} are belong to us.\n", .{val});
}

fn quartToBlock(val: i32) i32 {
    return val << 2;
}
fn blockToQuart(val: i32) i32 {
    return val >> 2;
}
