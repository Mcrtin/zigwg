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
pub const Position = struct {
    x: i32,
    y: i32,
    z: i32,
};
pub const NoisePosition = mf64.Vec3;

const NoiseHolder = makeNoiseHolderType(mcg.worldgen.noise);
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
        @field(res, curr.name) = .init(rng_type, &random, @field(noise_data, curr.name), true);
    }
    return res;
}
pub fn getNoise(noise_holder: anytype, comptime name: []const u8) noises.NormalNoise(@TypeOf(@field(noise_holder, name)).octaves) {
    return @field(noise_holder, name);
}

pub fn evalDensityFunction(comptime df_val: mcg.worldgen.density_function.DensityF, pos: Position, ctx: anytype) f64 {
    switch (df_val) {
        .object => |df| return evalDf(df, pos, ctx),
        .number => |n| return n,
        .string => |s| return evalDensityFunction(@field(mcg.worldgen.density_function, s), pos, ctx),
    }
}

fn evalDf(comptime df: *const mcg.worldgen.density_function.DensityFunction, pos: Position, ctx: anytype) f64 {
    switch (df.*) {
        .@"minecraft:interpolated" => |val| {
            return evalDensityFunction(val.argument, pos, ctx);
        },
        .@"minecraft:cache_2d" => |val| {
            return evalDensityFunction(val.argument, pos, ctx);
        },
        .@"minecraft:cache_once" => |val| {
            return evalDensityFunction(val.argument, pos, ctx);
        },
        .@"minecraft:flat_cache" => |val| {
            return evalDensityFunction(val.argument, pos, ctx);
        },
        .@"minecraft:blend_density" => |val| {
            return evalDensityFunction(val.argument, pos, ctx);
        },
        .@"minecraft:blend_alpha" => {
            return 1.0;
        },
        .@"minecraft:blend_offset" => {
            return 0.0;
        },
        .@"minecraft:old_blended_noise" => |val| {
            return ctx.blended_noise.compute(.new(@floatFromInt(pos.x), @floatFromInt(pos.y), @floatFromInt(pos.z)), val.xz_scale, val.y_scale, val.xz_factor, val.y_factor, val.smear_scale_multiplier);
        },
        .@"minecraft:range_choice" => |val| {
            const cond = evalDensityFunction(val.input, pos, ctx);
            return if (val.min_inclusive <= cond and cond < val.max_exclusive)
                evalDensityFunction(val.when_in_range, pos, ctx)
            else
                evalDensityFunction(val.when_out_of_range, pos, ctx);
        },
        .@"minecraft:clamp" => |val| {
            return std.math.clamp(evalDensityFunction(val.input, pos, ctx), val.min, val.max);
        },
        .@"minecraft:noise" => |val| {
            var noise_pos: NoisePosition = .new(@floatFromInt(pos.x), @floatFromInt(pos.y), @floatFromInt(pos.z));
            noise_pos.x *= val.xz_scale;
            noise_pos.y *= val.y_scale;
            noise_pos.z *= val.xz_scale;
            return evalNoise(val.noise, noise_pos, ctx);
        },
        .@"minecraft:add" => |val| {
            return evalDensityFunction(val.argument1, pos, ctx) + evalDensityFunction(val.argument2, pos, ctx);
        },
        .@"minecraft:mul" => |val| {
            return evalDensityFunction(val.argument1, pos, ctx) * evalDensityFunction(val.argument2, pos, ctx);
        },
        .@"minecraft:min" => |val| {
            return @min(evalDensityFunction(val.argument1, pos, ctx), evalDensityFunction(val.argument2, pos, ctx));
        },
        .@"minecraft:max" => |val| {
            return @max(evalDensityFunction(val.argument1, pos, ctx), evalDensityFunction(val.argument2, pos, ctx));
        },
        .@"minecraft:abs" => |val| {
            return @abs(evalDensityFunction(val.argument, pos, ctx));
        },
        .@"minecraft:square" => |val| {
            const res = evalDensityFunction(val.argument, pos, ctx);
            return res * res;
        },
        .@"minecraft:cube" => |val| {
            const res = evalDensityFunction(val.argument, pos, ctx);
            return res * res * res;
        },
        .@"minecraft:half_negative" => |val| {
            const res = evalDensityFunction(val.argument, pos, ctx);
            return if (res > 0.0) res else res / 2;
        },
        .@"minecraft:quarter_negative" => |val| {
            const res = evalDensityFunction(val.argument, pos, ctx);
            return if (res > 0.0) res else res / 4;
        },
        .@"minecraft:squeeze" => |val| {
            const res = std.math.clamp(evalDensityFunction(val.argument, pos, ctx), -1.0, 1.0);
            return res / 2 - res * res * res / 24;
        },
        .@"minecraft:invert" => |val| {
            return -evalDensityFunction(val.argument, pos, ctx);
        },
        .@"minecraft:y_clamped_gradient" => |val| {
            return math.clampedMap(@floatFromInt(pos.y), @floatFromInt(val.from_y), @floatFromInt(val.to_y), val.from_value, val.to_value);
        },
        .@"minecraft:weird_scaled_sampler" => |val| {
            const value = evalDensityFunction(val.input, pos, ctx);
            const mapped: f64 = if (comptime std.mem.eql(u8, val.rarity_value_mapper, "type_1"))
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
            else if (comptime std.mem.eql(u8, val.rarity_value_mapper, "type_2")) (if (value < -0.5)
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
        },
        .@"minecraft:shifted_noise" => |val| {
            var noise_pos: NoisePosition = .new(@floatFromInt(pos.x), @floatFromInt(pos.y), @floatFromInt(pos.z));
            noise_pos.x *= val.xz_scale;
            noise_pos.y *= val.y_scale;
            noise_pos.z *= val.xz_scale;

            noise_pos.x += evalDensityFunction(val.shift_x, pos, ctx);
            noise_pos.y += evalDensityFunction(val.shift_y, pos, ctx);
            noise_pos.z += evalDensityFunction(val.shift_z, pos, ctx);

            return evalNoise(val.noise, noise_pos, ctx);
        },
        .@"minecraft:find_top_surface" => |val| {
            const min = evalDensityFunction(val.lower_bound, pos, ctx);
            const max = evalDensityFunction(val.upper_bound, pos, ctx);
            var y: i32 = @intFromFloat(max);
            while (y >= min) : (y -= val.cell_height) {
                var curr_pos = pos;
                curr_pos.y = y;
                const res = evalDensityFunction(val.density, curr_pos, ctx);
                if (res > 0.390625) return y;
            }
            return @floatFromInt(std.math.maxInt(i32));
        },
        .@"minecraft:shift_a" => |val| {
            return evalNoise(val.argument, .{ .x = @floatFromInt(pos.x), .y = 0, .z = @floatFromInt(pos.z) }, ctx);
        },
        .@"minecraft:shift_b" => |val| {
            return evalNoise(val.argument, .{ .x = @floatFromInt(pos.z), .y = @floatFromInt(pos.x), .z = 0 }, ctx);
        },
        .@"minecraft:spline" => |val| {
            return @floatCast(evalSpline(val.spline, pos, ctx));
        },
        .@"minecraft:end_islands" => {
            @compileError("TODO");
        },
    }
}
fn evalNoise(comptime noise_name: Id, pos: NoisePosition, ctx: anytype) f64 {
    return getNoise(ctx.noise_holder, noise_name).getValue(pos);
}

fn evalSpline(comptime val: mcg.worldgen.density_function.SplineValue, pos: Position, ctx: anytype) f32 {
    switch (val) {
        .object => |spline| {
            const points = spline.points;

            const location: f32 = @floatCast(evalDensityFunction(spline.coordinate, pos, ctx));

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
        },
        .number => |n| return n,
    }
    unreachable;
}
