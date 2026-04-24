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

const MyRTree = RTree(TODO, 6);

// protected long distance(long[] values) {
//     long l = 0L;
//
//     for (int i = 0; i < 7; i++) {
//         l += Mth.square(this.parameterSpace[i].distance(values[i]));
//     }
//
//     return l;
// }
pub fn RTree(comptime T: type, comptime ParameterSpace: type, comptime ParameterInstance: type, comptime pspace_size: usize, comptime metric: fn (node: Node, searchedValues: []const i64) i64, comptime comparator: fn (pspace: ParameterSpace, pInstance: ParameterInstance) usize, comptime children_per_node: usize) type {
    return struct {
        root: Node,
        last: ?T,

        pub fn create(nodes: anytype) @This() {
            std.debug.assert(nodes.len > 0);
            // const list = nodes.stream().map(node -> new Climate.RTree.Leaf<>(node.getFirst(), node.getSecond()))
            //         .collect(Collectors.toCollection(ArrayList::new));
            // return new Climate.RTree<>(build(size, list));
        }

        // private static <T> Climate.RTree.Node<T> build(int paramSpaceSize,
        //         List<? extends Climate.RTree.Node<T>> children) {
        //     if (children.isEmpty()) {
        //         throw new IllegalStateException("Need at least one child to build a node");
        //     } else if (children.size() == 1) {
        //         return (Climate.RTree.Node<T>) children.get(0);
        //     } else if (children.size() <= 6) {
        //         children.sort(Comparator.comparingLong(child -> {
        //             long l2 = 0L;
        //
        //             for (int i2 = 0; i2 < paramSpaceSize; i2++) {
        //                 Climate.Parameter parameter = child.parameterSpace[i2];
        //                 l2 += Math.abs((parameter.min() + parameter.max()) / 2L);
        //             }
        //
        //             return l2;
        //         }));
        //         return new Climate.RTree.SubTree<>(children);
        //     } else {
        //         long l = Long.MAX_VALUE;
        //         int i = -1;
        //         List<Climate.RTree.SubTree<T>> list = null;
        //
        //         for (int i1 = 0; i1 < paramSpaceSize; i1++) {
        //             sort(children, paramSpaceSize, i1, false);
        //             List<Climate.RTree.SubTree<T>> list1 = bucketize(children);
        //             long l1 = 0L;
        //
        //             for (Climate.RTree.SubTree<T> subTree : list1) {
        //                 l1 += cost(subTree.parameterSpace);
        //             }
        //
        //             if (l > l1) {
        //                 l = l1;
        //                 i = i1;
        //                 list = list1;
        //             }
        //         }
        //
        //         sort(list, paramSpaceSize, i, true);
        //         return new Climate.RTree.SubTree<>(
        //                 list.stream().map(subTree1 -> build(paramSpaceSize, Arrays.asList(subTree1.children)))
        //                         .collect(Collectors.toList()));
        //     }
        // }
        //
        fn sort(children: []Node, comptime size: usize,
                 comptime absolute: bool) void {

std.mem.sort(Node, children, {}, struct {
    fn lessThan(_: void, a: Node, b: Node) bool {

            const comparator = comparator(size, absolute);
            for (int i = 1; i < pspace_size; i++) {
                comparator = comparator.thenComparing(comparator((size + i) % paramSpaceSize, absolute));
            }

    }
}.lessThan);
        }

        fn comparator(comptime size: usize, comptime absolute: bool) fn lessThan(_: void, a: Node, b: Node)bool {
        return struct {fn lessThan(_: void, a: Node, b: Node) bool {
        const a_val = blk: {
                const l = (a.parameter_space[size].min + a.parameter_space[size].max) / 2L;
            break :blk if (absolute) @abs(l) else l;
        };
        const b_val = blk: {
                            const l = (b.parameter_space[size].min + b.parameter_space[size].max) / 2L;
                        break :blk if (absolute) @abs(l) else l;

        };
        return a_val < b_val;
    }}.lessThan;
        }

        fn bucketize(nodes: []const Node) []const Node {
            List<Climate.RTree.SubTree<T>> list = Lists.newArrayList();
            List<Climate.RTree.Node<T>> list1 = Lists.newArrayList();
            const i = std.math.pow(usize, children_per_node, @floor(@log(nodes.len - 0.01) / @log(children_per_node)));


            for (nodes) |node| {
                list1.add(node);
                if (list1.size() >= i) {
                    list.add(new Climate.RTree.SubTree<>(list1));
                    list1 = Lists.newArrayList();
                }
            }

            if (!list1.isEmpty()) {
                list.add(new Climate.RTree.SubTree<>(list1));
            }

            return list;
        }

        fn cost(parameters: []const ParameterInstance) u64 {
            var res: u64 = 0;
            for (parameters) |parameter| res += parameter.max - parameter.min;
            return res;
        }

        fn buildParameterSpace(children: []const Node) Node {
            var res: []ParameterInstance = @span(.{});
            for (children) |child| for (res, child.parameter_space) |curr, pspace| curr.merge(pspace);
            return res;
        }

        pub fn search(self: *@This(), targetPoint: ParameterInstance) T {
            const res = self.root.search(targetPoint, self.last);
            self.last = res;
            return res;
        }

        const Node = struct {
            parameter_space: ParameterSpace,
            value: union(enum) {
                children: *[children_per_node]Node,
                value: T,
            },
            fn search(self: @This(), instance: ParameterInstance, last: ?T) T {
                switch (self.value) {
                    .children => |children| {
                        var best_dist = if (last) |l| metric(l, instance) else std.math.maxInt(i64);
                        var best = last;

                        for (children) |node| {
                            if (best_dist > metric(node, instance)) {
                                const res = node.search(instance, best);
                                const curr_dist = metric(res, instance);
                                if (best_dist > curr_dist) {
                                    best_dist = curr_dist;
                                    best = res;
                                }
                            }
                        }

                        return best.?;
                    },
                    .value => |val| return val,
                }
            }
        };
    };
}
