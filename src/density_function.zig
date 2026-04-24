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
    var names: [decls.len][]const u8 = undefined;
    var types: [decls.len]type = undefined;
    inline for (decls, &names, &types) |curr, *name, *@"type"| {
        name.* = curr.name;
        @"type".* = noises.NormalNoise(@field(noise_data, curr.name).amplitudes.len);
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

pub fn initNoiseHolder(noise_data: type, rng_type: type, rng_factory: rng.Factory(rng_type)) NoiseHolder {
    var res: NoiseHolder = undefined;
    inline for (@typeInfo(@TypeOf(res)).@"struct".fields) |curr| {
        var random = rng_factory.fromHashOf(curr.name);
        @field(res, curr.name) = .init(rng_type, &random, @field(noise_data, curr.name), true);
    }
    return res;
}

pub fn getNoise(noise_holder: anytype, comptime name: []const u8) noises.NormalNoise(@TypeOf(@field(noise_holder, name)).octaves) {
    comptime std.debug.assert(@hasField(@TypeOf(noise_holder), name));
    return @field(noise_holder, name);
}

fn evalNoise(comptime noise_name: Id, pos: NoisePosition, ctx: anytype) f64 {
    return getNoise(ctx.noise_holder, noise_name).getValue(pos);
}

pub fn DfEvaluator(comptime settings: mcg.worldgen.noise_settings) type {
    const context = constructRouterContext(settings.noise_router);
    const cell_width: u5 = @intCast(quartToBlock(settings.noise.size_horizontal));
    const chunk_height = settings.noise.height;
    const cell_height: u5 = @intCast(quartToBlock(settings.noise.size_horizontal));
    const min_y = settings.noise.min_y;
    // const max_y = min_y + chunk_height;
    const Random = if (settings.legacy_random_source) rng.Legacy else rng.Xoroshiro;
    return struct {
        const Evaluator = @This();
        chunk: Pos.Chunk,
        blended_noise: noises.Blended,
        interpolators: [context.interpolators.len]@This().Interpolator,
        cache2d: [context.cache2d.len]Cache2d,
        cache_once: [context.cache_once.len]CacheOnce,
        flat_caches: [context.flat_caches.len]FlatCache,
        noise: NoiseHolder,

        pub fn init(chunk: Pos.Chunk, rng_factory: rng.Factory(Random)) @This() {
            var blended_random = if (settings.legacy_random_source) rng.Rng(rng.Legacy).init(.init(0)) else rng_factory.fromHashOf("minecraft:terrain");
            return .{
                .chunk = chunk,
                .blended_noise = .create(Random, &blended_random),
                .noise = initNoiseHolder(mcg.worldgen.noise, Random, rng_factory),
                .interpolators = @splat(.{}),
                .cache2d = @splat(.{}),
                .cache_once = @splat(.{}),
                .flat_caches = @splat(.{}),
            };
        }

        pub fn evalDensityFunction(self: *@This(), comptime df_val: mcg.worldgen.density_function.DensityF, pos: Pos.Block) f64 {
            switch (df_val) {
                .object => |df| return self.evalDf(df, pos),
                .number => |n| return n,
                .string => |s| {
                    return self.evalDensityFunction(@field(mcg.worldgen.density_function, s), pos);
                },
            }
        }

        fn evalSpline(self: *@This(), comptime val: mcg.worldgen.density_function.SplineValue, pos: Pos.Block) f32 {
            switch (val) {
                .object => |spline| {
                    const points = spline.points;

                    const location: f32 = @floatCast(self.evalDensityFunction(spline.coordinate, pos));

                    inline for (points, 0..points.len) |hi, idx| {
                        if (location < hi.location) {
                            if (idx == 0) {
                                return self.evalSpline(hi.value, pos) + hi.derivative * (location - hi.location);
                            }
                            const lo = points[idx - 1];

                            const lo_val = self.evalSpline(lo.value, pos);
                            const hi_val = self.evalSpline(hi.value, pos);

                            const delta = (location - lo.location) / (hi.location - lo.location);

                            const start = lo.derivative * (hi.location - lo.location) - (hi_val - lo_val);
                            const end = -hi.derivative * (hi.location - lo.location) + (hi_val - lo_val);
                            return math.lerpf(delta, lo_val, hi_val) + delta * (1.0 - delta) * math.lerpf(delta, start, end);
                        }
                    }
                    const lo = points[points.len - 1];
                    return self.evalSpline(lo.value, pos) + lo.derivative * (location - lo.location);
                },
                .number => |n| return n,
            }
            comptime unreachable;
        }

        inline fn evalDf(self: *@This(), comptime df: *const mcg.worldgen.density_function.DensityFunction, pos: Pos.Block) f64 {
            switch (df.*) {
                .@"minecraft:constant" => |val| return val.argument,
                .@"minecraft:interpolated" => |val| {
                    return self.getInterpolator(resolvedf(val.argument).?).compute(val.argument, pos, self);
                },
                .@"minecraft:cache_2d" => |val| {
                    return self.getCache2d(resolvedf(val.argument).?).compute(val.argument, pos, self);
                },
                .@"minecraft:cache_once" => |val| {
                    return self.getCacheOnce(resolvedf(val.argument).?).compute(val.argument, pos, self);
                },
                .@"minecraft:flat_cache" => |val| {
                    return self.getFlatCache(resolvedf(val.argument).?).compute(val.argument, pos, self);
                },
                .@"minecraft:blend_density" => |val| {
                    return self.evalDensityFunction(val.argument, pos);
                },
                .@"minecraft:blend_alpha" => {
                    return 1.0;
                },
                .@"minecraft:blend_offset" => {
                    return 0.0;
                },
                .@"minecraft:old_blended_noise" => |val| {
                    return self.blended_noise.compute(.fromBlock(pos), val.xz_scale, val.y_scale, val.xz_factor, val.y_factor, val.smear_scale_multiplier);
                },
                .@"minecraft:range_choice" => |val| {
                    const cond = self.evalDensityFunction(val.input, pos);
                    if (val.min_inclusive <= cond and cond < val.max_exclusive)
                        return self.evalDensityFunction(val.when_in_range, pos)
                    else
                        return self.evalDensityFunction(val.when_out_of_range, pos);
                },
                .@"minecraft:clamp" => |val| {
                    return std.math.clamp(self.evalDensityFunction(val.input, pos), val.min, val.max);
                },
                .@"minecraft:noise" => |val| {
                    const noise_pos = NoisePosition.fromBlock(pos).mul(.fromXZandY(val.xz_scale, val.y_scale));
                    return self.evalNoise(val.noise, noise_pos);
                },
                .@"minecraft:add" => |val| {
                    return self.evalDensityFunction(val.argument1, pos) + self.evalDensityFunction(val.argument2, pos);
                },
                .@"minecraft:mul" => |val| {
                    return self.evalDensityFunction(val.argument1, pos) * self.evalDensityFunction(val.argument2, pos);
                },
                .@"minecraft:min" => |val| {
                    return @min(self.evalDensityFunction(val.argument1, pos), self.evalDensityFunction(val.argument2, pos));
                },
                .@"minecraft:max" => |val| {
                    return @max(self.evalDensityFunction(val.argument1, pos), self.evalDensityFunction(val.argument2, pos));
                },
                .@"minecraft:abs" => |val| {
                    return @abs(self.evalDensityFunction(val.argument, pos));
                },
                .@"minecraft:square" => |val| {
                    const res = self.evalDensityFunction(val.argument, pos);
                    return res * res;
                },
                .@"minecraft:cube" => |val| {
                    const res = self.evalDensityFunction(val.argument, pos);
                    return res * res * res;
                },
                .@"minecraft:half_negative" => |val| {
                    const res = self.evalDensityFunction(val.argument, pos);
                    return if (res > 0.0) res else res / 2;
                },
                .@"minecraft:quarter_negative" => |val| {
                    const res = self.evalDensityFunction(val.argument, pos);
                    return if (res > 0.0) res else res / 4;
                },
                .@"minecraft:squeeze" => |val| {
                    const res = std.math.clamp(self.evalDensityFunction(val.argument, pos), -1.0, 1.0);
                    return res / 2 - res * res * res / 24;
                },
                .@"minecraft:invert" => |val| {
                    return -self.evalDensityFunction(val.argument, pos);
                },
                .@"minecraft:y_clamped_gradient" => |val| {
                    return math.clampedMap(
                        @floatFromInt(pos.y),
                        @floatFromInt(val.from_y),
                        @floatFromInt(val.to_y),
                        val.from_value,
                        val.to_value,
                    );
                },
                .@"minecraft:weird_scaled_sampler" => |val| {
                    const value = self.evalDensityFunction(val.input, pos);
                    const mapped: f64 = if (comptime std.mem.eql(u8, val.rarity_value_mapper, "type_1"))
                        (if (value < -0.75) 0.5 else if (value < -0.5) 0.75 else if (value < 0.5) 1.0 else if (value < 0.75) 2.0 else 3.0)
                    else if (comptime std.mem.eql(u8, val.rarity_value_mapper, "type_2"))
                        (if (value < -0.5) 0.75 else if (value < 0.0) 1.0 else if (value < 0.5) 1.5 else 2.0)
                    else
                        @compileError("unsupported rarity value mapper " ++ val.rarity_value_mapper);
                    const noise_pos = NoisePosition.fromBlock(pos).scale(1 / mapped);
                    return mapped * @abs(self.evalNoise(val.noise, noise_pos));
                },
                .@"minecraft:shifted_noise" => |val| {
                    const noise_pos = NoisePosition.fromBlock(pos).mul(.fromXZandY(val.xz_scale, val.y_scale))
                        .add(.new(
                        self.evalDensityFunction(val.shift_x, pos),
                        self.evalDensityFunction(val.shift_y, pos),
                        self.evalDensityFunction(val.shift_z, pos),
                    ));
                    return self.evalNoise(val.noise, noise_pos);
                },
                .@"minecraft:find_top_surface" => |val| {
                    const min = self.evalDensityFunction(val.lower_bound, pos);
                    const max = self.evalDensityFunction(val.upper_bound, pos);
                    var y: i32 = @intFromFloat(max);
                    while (y >= min) : (y -= val.cell_height) {
                        if (self.evalDensityFunction(val.density, pos.column.block(y)) > 0.390625) return y;
                    }
                    return @floatFromInt(std.math.maxInt(i32));
                },
                .@"minecraft:shift_a" => |val| {
                    return self.evalNoise(val.argument, .new(@floatFromInt(pos.column.x), 0, @floatFromInt(pos.column.z)));
                },
                .@"minecraft:shift_b" => |val| {
                    return self.evalNoise(val.argument, .new(@floatFromInt(pos.column.z), @floatFromInt(pos.column.x), 0));
                },
                .@"minecraft:spline" => |val| {
                    return @floatCast(self.evalSpline(val.spline, pos));
                },
                .@"minecraft:end_islands" => {
                    const ISLAND_THRESHOLD = -0.9;
                    const noise: Simplex = blk: {
                        var random: rng.Rng(rng.Legacy) = .init(.init(0));
                        random.consumeCount(17292);
                        break :blk .init(rng.Legacy, &random);
                    };

                    const x = pos.column.x / 8;
                    const z = pos.column.z / 8;

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
                .@"minecraft:cache_all_in_cell",
                .@"minecraft:shift",
                => comptime unreachable,
            }
            comptime unreachable;
        }

        fn getInterpolator(self: *@This(), comptime df: *const mcg.worldgen.density_function.DensityFunction) *Interpolator {
            inline for (context.interpolators, &self.interpolators) |n, *interpolator| {
                if (comptime n == df) return interpolator;
            }
            comptime unreachable;
        }
        fn getFlatCache(self: *@This(), comptime df: *const mcg.worldgen.density_function.DensityFunction) *FlatCache {
            inline for (context.flat_caches, &self.flat_caches) |n, *cache| {
                if (comptime n == df) return cache;
            }
            comptime unreachable;
        }
        fn getCache2d(self: *@This(), comptime df: *const mcg.worldgen.density_function.DensityFunction) *Cache2d {
            inline for (context.cache2d, &self.cache2d) |n, *cache| {
                if (comptime n == df) return cache;
            }
            comptime unreachable;
        }
        fn getCacheOnce(self: *@This(), comptime df: *const mcg.worldgen.density_function.DensityFunction) *CacheOnce {
            inline for (context.cache_once, &self.cache_once) |n, *cache| {
                if (comptime n == df) return cache;
            }
            comptime unreachable;
        }

        inline fn evalNoise(self: *const @This(), comptime noise_name: Id, pos: NoisePosition) f64 {
            return getNoise(self.noise, noise_name).getValue(pos);
        }

        pub const Interpolator = struct {
            const z_cells_per_chunk = @divExact(Pos.Chunk.Resolution, cell_width);
            const y_cells_per_chunk = @divExact(chunk_height, @as(Pos.Height, cell_height));
            const cell_to_block: Pos.Block = .init(cell_width, cell_height, cell_width);

            data: [2][z_cells_per_chunk + 1][y_cells_per_chunk + 1]f64 = @splat(@splat(@splat(std.math.nan(f64)))),
            x: u5 = 14,

            pub inline fn compute(self: *@This(), comptime df_val: mcg.worldgen.density_function.DensityF, pos: Pos.Block, evaluator: *Evaluator) f64 {
                // if (self.first) {
                //     self.first = false;
                //     std.debug.print("first pos: {any}\n", .{pos});
                // }
                const chunk_block = pos.chunkBlock();
                const curr_x = chunk_block.column.x / cell_width;
                if (curr_x != self.x) {
                    for (0..if (curr_x == self.x + 1) 1 else 2) |xo| {
                        self.data[0] = self.data[1];
                        for (&self.data[1], 0..) |*zslice, zo| {
                            for (zslice, 0..) |*val, yo| {
                                const origin = pos.column.chunk().origin().block(min_y);
                                const offset: Pos.Block = .init(curr_x + @as(u1, @intCast(xo)), @intCast(yo), @intCast(zo));
                                const p = origin.add(offset.mul(cell_to_block) catch unreachable) catch unreachable;

                                val.* = evaluator.evalDensityFunction(df_val, p);
                            }
                        }
                    }
                }
                self.x = curr_x;

                const y = @divFloor(@as(u12, @intCast(chunk_block.y - min_y)), cell_height);
                const z = @divFloor(chunk_block.column.z, cell_width);
                // if (chunk_block.column.x == 0) {
                //     if (self.data[0][z][y] != self.data[1][z][y])
                //         std.debug.print("val: {any} {any}\n", .{ self.data[0][z][y], self.data[1][z][y] });
                // }
                const val = math.lerp3(
                    math.modNorm(pos.y, cell_height),
                    math.modNorm(pos.column.x, cell_width),
                    math.modNorm(pos.column.z, cell_width),
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
        };

        pub const Cache2d = struct {
            last_pos: ?Pos.Column = null,
            val: f64 = undefined,
            inline fn compute(self: *@This(), comptime df: mcg.worldgen.density_function.DensityF, pos: Pos.Block, evaluator: *Evaluator) f64 {
                if (self.last_pos) |p| if (p == pos.column) return self.val;
                self.val = evaluator.evalDensityFunction(df, pos);
                self.last_pos = pos.column;
                return self.val;
            }
        };

        pub const CacheOnce = struct {
            last_pos: ?Pos.Block = null,
            val: f64 = undefined,
            pub inline fn compute(self: *@This(), comptime df: mcg.worldgen.density_function.DensityF, pos: Pos.Block, evaluator: *Evaluator) f64 {
                if (self.last_pos) |p| if (p == pos) return self.val;
                self.val = evaluator.evalDensityFunction(df, pos);
                self.last_pos = pos;
                return self.val;
            }
        };

        pub const FlatCache = struct {
            const xz_size = (Pos.Chunk.Resolution >> 2) + 1;
            values: [xz_size][xz_size]f64 = undefined,
            first: bool = true,

            pub inline fn compute(self: *@This(), comptime df: mcg.worldgen.density_function.DensityF, pos: Pos.Block, evaluator: *Evaluator) f64 {
                if (self.first)
                    for (&self.values, 0..) |*zslize, x|
                        for (zslize, 0..) |*val, z| {
                            val.* = evaluator.evalDensityFunction(df, evaluator.chunk.origin().block(0).add(.init(@intCast(x << 2), 0, @intCast(z << 2))) catch unreachable);
                        };

                self.first = false;
                const x = (pos.column.x - evaluator.chunk.x) >> 2;
                const z = (pos.column.z - evaluator.chunk.z) >> 2;
                return if (0 <= x and x < xz_size and 0 <= z and z < xz_size)
                    self.values[@intCast(x)][@intCast(z)]
                else
                    evaluator.evalDensityFunction(df, pos);
            }
        };
    };
}

pub fn constructRouterContext(comptime router: mcg.worldgen.noise_settings.NoiseRouter) ConstructionContext {
    var context: ConstructionContext = .{};
    inline for (@typeInfo(@TypeOf(router)).@"struct".fields) |field|
        context = constructContext(@field(router, field.name), context);

    return context;
}

const ConstructionContext = struct {
    interpolators: []const *const mcg.worldgen.density_function.DensityFunction = &.{},
    cache2d: []const *const mcg.worldgen.density_function.DensityFunction = &.{},
    cache_once: []const *const mcg.worldgen.density_function.DensityFunction = &.{},
    flat_caches: []const *const mcg.worldgen.density_function.DensityFunction = &.{},
    noise: []const *const mcg.worldgen.noise = &.{}, //TODO remove
};

fn resolvedf(comptime df_val: mcg.worldgen.density_function.DensityF) ?*const mcg.worldgen.density_function.DensityFunction {
    switch (df_val) {
        .object => |df| return df,
        .string => |s| return resolvedf(@field(mcg.worldgen.density_function, s)),
        else => return null,
    }
}

fn constructContext(comptime df: mcg.worldgen.density_function.DensityF, context: ConstructionContext) ConstructionContext {
    var ctx = context;
    loop: switch ((resolvedf(df) orelse return ctx).*) {
        .@"minecraft:interpolated" => |val| {
            const resolved = resolvedf(val.argument).?;
            for (ctx.interpolators) |df_| {
                if (df_ == resolved) break;
            } else {
                ctx.interpolators = ctx.interpolators ++ .{resolved};
                continue :loop resolved.*;
            }
        },
        .@"minecraft:cache_2d" => |val| {
            const resolved = resolvedf(val.argument).?;
            for (ctx.cache2d) |df_| {
                if (df_ == resolved) break;
            } else {
                ctx.cache2d = ctx.cache2d ++ .{resolved};
                continue :loop resolved.*;
            }
        },
        .@"minecraft:cache_once" => |val| {
            const resolved = resolvedf(val.argument).?;
            for (ctx.cache_once) |df_| {
                if (df_ == resolved) break;
            } else {
                ctx.cache_once = ctx.cache_once ++ .{resolved};
                continue :loop resolved.*;
            }
        },
        .@"minecraft:flat_cache" => |val| {
            const resolved = resolvedf(val.argument).?;
            for (ctx.flat_caches) |df_| {
                if (df_ == resolved) break;
            } else {
                ctx.flat_caches = ctx.flat_caches ++ .{resolved};
                continue :loop resolved.*;
            }
        },
        .@"minecraft:range_choice" => |val| {
            ctx = constructContext(val.when_in_range, ctx);
            ctx = constructContext(val.when_out_of_range, ctx);
            continue :loop (resolvedf(val.input) orelse return ctx).*;
        },
        .@"minecraft:clamp" => |val| continue :loop (resolvedf(val.input) orelse return ctx).*,
        .@"minecraft:noise" => |val| {
            _ = val; // autofix
            // const noise = @field(mcg.worldgen.noise, val.noise);
            // for (ctx.noise) |df_| {
            //     if (df_ == noise) continue;
            // } else {
            //     ctx.noise ++ noise;
            // }
        },
        .@"minecraft:add", .@"minecraft:mul", .@"minecraft:min", .@"minecraft:max" => |val| {
            ctx = constructContext(val.argument1, ctx);
            continue :loop (resolvedf(val.argument2) orelse return ctx).*;
        },
        .@"minecraft:weird_scaled_sampler" => |val| {
            // const noise = @field(mcg.worldgen.noise, val.noise);
            // for (ctx.noise) |df_| {
            //     if (df_ == noise) continue;
            // } else {
            //     ctx.noise ++ noise;
            // }
            continue :loop (resolvedf(val.input) orelse return ctx).*;
        },
        .@"minecraft:shifted_noise" => |val| {
            // const noise = @field(mcg.worldgen.noise, val.noise);
            // for (ctx.noise) |df_| {
            //     if (df_ == noise) continue;
            // } else {
            //     ctx.noise ++ noise;
            // }
            ctx = constructContext(val.shift_x, ctx);
            ctx = constructContext(val.shift_y, ctx);
            continue :loop (resolvedf(val.shift_z) orelse return ctx).*;
        },
        .@"minecraft:find_top_surface" => |val| {
            ctx = constructContext(val.lower_bound, ctx);
            ctx = constructContext(val.upper_bound, ctx);
            continue :loop (resolvedf(val.density) orelse return ctx).*;
        },
        .@"minecraft:shift_b", .@"minecraft:shift_a" => |val| {
            _ = val; // autofix
            // const noise = @field(mcg.worldgen.noise, val.argument);
            // for (ctx.noise) |df_| {
            //     if (df_ == noise) continue;
            // } else {
            //     ctx.noise ++ noise;
            // }
        },
        .@"minecraft:blend_density",
        .@"minecraft:abs",
        .@"minecraft:square",
        .@"minecraft:cube",
        .@"minecraft:half_negative",
        .@"minecraft:quarter_negative",
        .@"minecraft:squeeze",
        .@"minecraft:invert",
        => |val| continue :loop (resolvedf(val.argument) orelse return ctx).*,

        .@"minecraft:constant",
        .@"minecraft:blend_alpha",
        .@"minecraft:blend_offset",
        .@"minecraft:old_blended_noise",
        .@"minecraft:spline",
        .@"minecraft:end_islands",
        .@"minecraft:y_clamped_gradient",
        => {},
        .@"minecraft:shift",
        .@"minecraft:cache_all_in_cell",
        => comptime unreachable,
    }
    return ctx;
}
fn quartToBlock(val: i32) i32 {
    return val << 2;
}
fn blockToQuart(val: i32) i32 {
    return val >> 2;
}

test "spline" {

    // const cubic3 = CubicSpline::new(
    //     SplineType::Continents,
    //     vec![
    //         SplinePoint::constant(-1.1, 0.044, 0.0),
    //         SplinePoint::constant(-1.02, -0.2222, 0.0),
    //         SplinePoint::constant(-0.51, -0.2222, 0.0),
    //         SplinePoint::constant(-0.44, -0.12, 0.0),
    //         SplinePoint::constant(-0.18, -0.12, 0.0),
    //     ],
    // );
    // const spline = CubicSpline::new(
    //     SplineType::Continents,
    //     vec![
    //         SplinePoint::constant(-1.1, 0.044, 0.0),
    //         SplinePoint::constant(-1.02, -0.2222, 0.0),
    //         SplinePoint::constant(-0.51, -0.2222, 0.0),
    //         SplinePoint::constant(-0.44, -0.12, 0.0),
    //         SplinePoint::constant(-0.18, -0.12, 0.0),
    //         SplinePoint::spline(1.0, cubic3),
    //     ],
    // );
    // std.testing.expectEqual(-0.12, spline.sample(.zero))
}
