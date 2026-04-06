const mcg = @import("mc-generated");
const zigwg = @import("zigwg");
const rng = @import("rng.zig");
const meta = @import("meta.zig");
const mf64 = @import("zlm").as(f64);
const math = @import("math.zig");
const std = @import("std");
const noises = @import("noise.zig");
const Id = []const u8;
const Simplex = @import("noise.zig").Simplex;
const Pos = @import("position.zig");

pub const NoisePosition = noises.Position;

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
    inline for (@typeInfo(@TypeOf(res)).@"struct".decls) |curr| {
        var random = rng_factory.fromHashOf("minecraft:" ++ curr.name);
        @field(res, curr.name) = .init(rng_type, &random, @field(noise_data, curr.name), true);
    }
    return res;
}
pub fn getNoise(noise_holder: anytype, comptime name: []const u8) noises.NormalNoise(@TypeOf(@field(noise_holder, name)).octaves) {
    return @field(noise_holder, name);
}

pub fn evalDensityFunction(comptime df_val: mcg.worldgen.density_function.DensityF, pos: Pos.Block, ctx: anytype) f64 {
    switch (df_val) {
        .object => |df| return evalDf(df, pos, ctx),
        .number => |n| return n,
        .string => |s| return evalDensityFunction(@field(mcg.worldgen.density_function, s), pos, ctx),
    }
}

pub fn Interpolator(comptime cell_width: u5, comptime cell_height: u5, comptime chunk_height: Pos.Height) type {
    return struct {
        const z_cells_per_chunk = @divExact(Pos.Chunk.Resolution, cell_width);
        const y_cells_per_chunk = @divExact(chunk_height, @as(Pos.Height, cell_height));
        const cell_to_block: Pos.Block = .init(cell_width, cell_height, cell_width);

        data: [2][z_cells_per_chunk + 1][y_cells_per_chunk + 1]f64 = @splat(@splat(@splat(0))),

        pub fn compute(self: *@This(), comptime df_val: mcg.worldgen.density_function.DensityF, pos: Pos.Block, ctx: anytype) f64 {
            const chunk_block = pos.chunkBlock();
            if (chunk_block.column.x % cell_width == 0 and chunk_block.y == ctx.max_y - 1 and chunk_block.column.z == 0) {
                for (0..if (chunk_block.column.x == 0) 2 else 1) |_| {
                    self.data[0] = self.data[1];
                    for (&self.data[1], 0..) |*zslice, zo| {
                        for (zslice, 0..) |*val, yo| {
                            const origin = pos.column.chunk().origin().block(ctx.min_y);
                            const offset: Pos.Block = .init(@divExact(chunk_block.column.x, cell_width), @intCast(yo), @intCast(zo));
                            const p = origin.add(offset.mul(cell_to_block) catch unreachable) catch unreachable;
                            val.* = evalDensityFunction(df_val, p, ctx);
                        }
                    }
                }
            }

            const y = @divFloor(@as(u12, @intCast(chunk_block.y - ctx.min_y)), cell_height);
            const z = @divFloor(chunk_block.column.z, cell_width);
            const val = math.lerp3(
                modNorm(pos.y, cell_height),
                modNorm(pos.column.x, cell_width),
                modNorm(pos.column.z, cell_width),
                self.data[0][z][y],
                self.data[0][z][y + 1],
                self.data[1][z][y],
                self.data[1][z][y + 1],
                self.data[0][z + 1][y],
                self.data[0][z + 1][y + 1],
                self.data[1][z + 1][y],
                self.data[1][z + 1][y + 1],
            );
            return val;
        }
        fn modNorm(numerator: anytype, denominator: anytype) f64 {
            return @as(f64, @floatFromInt(@mod(numerator, denominator))) / @as(f64, @floatFromInt(denominator));
        }
    };
}

fn evalDf(comptime df: *const mcg.worldgen.density_function.DensityFunction, pos: Pos.Block, ctx: anytype) f64 {
    switch (df.*) {
        .@"minecraft:interpolated" => |val| {
            var idx: usize = undefined;
            for (ctx.interpolator.density_functions[0..ctx.interpolator.count.*], 0..) |df_, i| {
                if (std.meta.eql(df_, val.argument)) {
                    idx = i;
                    break;
                }
            } else {
                idx = ctx.interpolator.count.*;
                std.debug.assert(idx < 10);
                ctx.interpolator.count.* += 1;
                ctx.interpolator.density_functions[idx] = val.argument;
                ctx.interpolator.interpolators[idx] = .{};
            }
            return ctx.interpolator.interpolators[idx].compute(val.argument, pos, ctx);
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
            return ctx.blended_noise.compute(.new(@floatFromInt(pos.column.x), @floatFromInt(pos.y), @floatFromInt(pos.column.z)), val.xz_scale, val.y_scale, val.xz_factor, val.y_factor, val.smear_scale_multiplier);
        },
        .@"minecraft:range_choice" => |val| {
            const cond = evalDensityFunction(val.input, pos, ctx);
            if (val.min_inclusive <= cond and cond < val.max_exclusive)
                return evalDensityFunction(val.when_in_range, pos, ctx)
            else
                return evalDensityFunction(val.when_out_of_range, pos, ctx);
        },
        .@"minecraft:clamp" => |val| {
            return std.math.clamp(evalDensityFunction(val.input, pos, ctx), val.min, val.max);
        },
        .@"minecraft:noise" => |val| {
            const noise_pos = NoisePosition.fromBlock(pos).mul(.fromXZandY(val.xz_scale, val.y_scale));
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
            const noise_pos = NoisePosition.fromBlock(pos).scale(1 / mapped);
            return mapped * @abs(evalNoise(val.noise, noise_pos, ctx));
        },
        .@"minecraft:shifted_noise" => |val| {
            const noise_pos = NoisePosition.fromBlock(pos).mul(.fromXZandY(val.xz_scale, val.y_scale))
                .add(.new(
                evalDensityFunction(val.shift_x, pos, ctx),
                evalDensityFunction(val.shift_y, pos, ctx),
                evalDensityFunction(val.shift_z, pos, ctx),
            ));
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
            return evalNoise(val.argument, .{ .x = @floatFromInt(pos.column.x), .y = 0, .z = @floatFromInt(pos.column.z) }, ctx);
        },
        .@"minecraft:shift_b" => |val| {
            return evalNoise(val.argument, .{ .x = @floatFromInt(pos.column.z), .y = @floatFromInt(pos.column.x), .z = 0 }, ctx);
        },
        .@"minecraft:spline" => |val| {
            return @floatCast(evalSpline(val.spline, pos, ctx));
        },
        .@"minecraft:end_islands" => {
            const ISLAND_THRESHOLD = -0.9;
            const noise: Simplex = blk: {
                var random: rng.Rng(rng.Legacy) = .init(.init(0));
                random.consumeCount(17292);
                break :blk .init(rng.Legacy, &random);
            };

            const x = pos.x / 8;
            const z = pos.z / 8;

            const i = x / 2;
            const i1_ = z / 2;
            const i2_ = x % 2;
            const i3_ = z % 2;
            var f = 100 - @sqrt(@as(f32, @floatFromInt(x * x + z * z))) * 8;
            f = std.math.clamp(f, -100, 80);

            for (-12..13) |i4_| {
                for (-12..13) |i5_| {
                    const l: i64 = i + i4_;
                    const l1: i64 = i1_ + i5_;
                    if (l * l + l1 * l1 > 4096 and noise.getValue(.new(l, l1)) < ISLAND_THRESHOLD) {
                        const f1 = (@abs(@as(f32, @floatFromInt(l))) * 3439 + @abs(@as(f32, @floatFromInt(l1))) * 147) % 13 + 9;
                        const f2: f32 = @floatFromInt(i2_ - i4_ * 2);
                        const f3: f32 = @floatFromInt(i3_ - i5_ * 2);
                        const f4 = 100 - @sqrt(f2 * f2 + f3 * f3) * f1;
                        f4 = std.math.clamp(f4, -100, 80);
                        f = @max(f, f4);
                    }
                }
            }
            return (f - 8) / 128;
        },
    }
    comptime unreachable;
}
fn evalNoise(comptime noise_name: Id, pos: NoisePosition, ctx: anytype) f64 {
    return getNoise(ctx.noise_holder, noise_name).getValue(pos);
}

fn evalSpline(comptime val: mcg.worldgen.density_function.SplineValue, pos: Pos.Block, ctx: anytype) f32 {
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
