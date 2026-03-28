const std = @import("std");
const mem = std.mem;
const math = std.math;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;

const generated = @import("mc-generated");
pub const Block = generated.blocks.Block;
pub const BlockState = generated.blocks.BlockState;
pub const Biome = generated.biomes.Biome;

// https://minecraft.fandom.com/wiki/Custom#JSON_format
//     Range for MIN_Y is [-2032, 2016], HEIGHT is [16, 4064]
//     MIN_Y and HEIGHT must be a multiple of 16
// TODO: is that mention about max build height another limit to be concerned about or
//     is that only the combination of the MIN_Y and HEIGHT?
pub const MIN_Y_MINIMUM = -2032;
pub const MIN_Y_MAXIMUM = 2016;
pub const HEIGHT_MINIMUM = 16;
pub const HEIGHT_MAXIMUM = 4064;
pub const MAX_Y_MINIMUM = MIN_Y_MINIMUM + HEIGHT_MINIMUM;
pub const MAX_Y_MAXIMUM = MIN_Y_MAXIMUM + HEIGHT_MAXIMUM;

pub const TOTAL_SECTIONS_MINIMUM = @divExact(HEIGHT_MINIMUM, 16);
pub const TOTAL_SECTIONS_MAXIMUM = @divExact(HEIGHT_MAXIMUM, 16);

pub const BIOME_MIN_Y_MINIMUM = @divExact(MIN_Y_MINIMUM, 4);
pub const BIOMY_MIN_Y_MAXIMUM = @divExact(MIN_Y_MAXIMUM, 4);
pub const BIOME_MAX_Y_MINIMUM = @divExact(MAX_Y_MINIMUM, 4);
pub const BIOME_MAX_Y_MAXIMUM = @divExact(MAX_Y_MAXIMUM, 4);
pub const BIOME_HEIGHT_MINIMUM = @divExact(HEIGHT_MINIMUM, 4);
pub const BIOME_HEIGHT_MAXIMUM = @divExact(HEIGHT_MAXIMUM, 4);

pub const BlockY = math.IntFittingRange(MIN_Y_MINIMUM, MAX_Y_MAXIMUM);
pub const UBlockY = math.IntFittingRange(0, HEIGHT_MAXIMUM);
pub const BiomeY = math.IntFittingRange(BIOME_MIN_Y_MINIMUM, BIOME_MAX_Y_MAXIMUM);
pub const UBiomeY = math.IntFittingRange(0, BIOME_HEIGHT_MAXIMUM);

pub inline fn blockYToU(y: BlockY, min_y: BlockY) UBlockY {
    return @intCast(y - min_y);
}
pub inline fn biomeYToU(y: BiomeY, min_y: BiomeY) UBiomeY {
    return @intCast(y - min_y);
}

const blockFields = @typeInfo(Block).@"enum".fields;
pub fn blockStateIdRangeForBlock(
    block: Block,
) struct {
    from: BlockState.Id,
    to: BlockState.Id,
} {
    const to_ind = @intFromEnum(block);
    return .{
        .from = Block.defaultStateId(block),
        .to = if (to_ind < Block.MaxId)
            (Block.defaultStateId(@field(Block, blockFields[to_ind + 1].name)) - 1)
        else
            Block.MaxId,
    };
}
pub fn isBlock(comptime block: Block, bsid: BlockState.Id) bool {
    const range = comptime blockStateIdRangeForBlock(block);
    return bsid >= range.from and bsid <= range.to;
}

pub fn blockIsMotionBlocking(bsid: BlockState.Id) bool {
    inline for (.{
        .air,            .void_air, .cave_air,
        .bamboo_sapling, .cactus,   .water,
        .lava,
    }) |block| {
        if (isBlock(block, bsid)) return false;
    }
    return true;
}
pub fn isAir(bsid: BlockState.Id) bool {
    inline for (.{
        .air, .void_air, .cave_air,
    }) |block| {
        if (isBlock(block, bsid)) return true;
    }
    return false;
}
pub fn blockIsWorldSurface(bsid: BlockState.Id) bool {
    return !isAir(bsid);
}

pub const Column = struct {
    const DefaultChunkSection = ChunkSection.UT{
        .block_count = 0,
        .blocks = .{ .single = Block.air.defaultStateId() },
        .biomes = .{ .single = @intFromEnum(Biome.plains) },
    };

    sections: []ChunkSection.UT,
    block_entities: std.AutoHashMapUnmanaged(
        struct { x: BlockAxis, z: BlockAxis, y: BlockY },
        BlockEntityData.UT,
    ) = .{},
    motion_blocking: HeightMap,
    world_surface: HeightMap,

    light_levels: LightLevels,

    pub inline fn height(self: Column) UBlockY {
        return @intCast(self.sections.len * 16);
    }

    pub fn initFlat(a: Allocator, section_count: usize) !Column {
        const heightmap_bits = math.log2_int_ceil(usize, section_count * 16);
        var self = Column{
            .sections = try a.alloc(ChunkSection.UT, section_count),
            .motion_blocking = .{
                .inner = HeightMap.InnerArray.initAll(@intCast(heightmap_bits), 0),
            },
            .world_surface = .{
                .inner = HeightMap.InnerArray.initAll(@intCast(heightmap_bits), 0),
            },
            .light_levels = undefined,
        };
        errdefer a.free(self.sections);
        self.light_levels = try LightLevels.initAll(a, 0xF, section_count);
        errdefer self.light_levels.deinit(.{ .allocator = a });
        @memset(self.sections, DefaultChunkSection);
        var y: UBlockY = 0;
        for (&[_]Block{
            .bedrock, .stone, .stone, .stone,
            .stone,   .stone, .stone, .stone,
            .dirt,    .dirt,  .dirt,  .grass_block,
        }) |block| {
            for (0..16) |z| for (0..16) |x|
                self.setBlock(@intCast(x), @intCast(z), y, block.defaultStateId());
            y += 1;
        }
        return self;
    }

    pub fn deinit(self: *Column, a: Allocator) void {
        a.free(self.sections);
        self.light_levels.deinit(.{ .allocator = a });
        var iter = self.block_entities.valueIterator();
        while (iter.next()) |e| BlockEntityData.deinit(e, .{ .allocator = a });
        self.block_entities.deinit(a);
        self.* = undefined;
    }

    pub fn blockAt(self: Column, x: BlockAxis, z: BlockAxis, y: UBlockY) BlockState.Id {
        return if (y < self.height())
            self.sections[y >> 4].blocks
                .get(x, z, @truncate(y))
        else
            comptime BlockState.toId(.air);
    }

    pub fn biomeAt(self: Column, x: BiomeAxis, z: BiomeAxis, y: UBiomeY) Biome.Id {
        return if (y < self.height() >> 2)
            self.sections[y >> 2].blocks.get(x, z, @truncate(y))
        else
            @intFromEnum(Biome.the_void);
    }

    pub fn setBlock(
        self: *Column,
        x: BlockAxis,
        z: BlockAxis,
        y: UBlockY,
        value: BlockState.Id,
    ) void {
        if (y >= self.height()) return;
        const section = &self.sections[y >> 4];
        const last_air = isAir(section.blocks.get(x, z, @truncate(y)));
        const new_air = isAir(value);
        section.blocks.set(x, z, @truncate(y), value);

        // update heightmap while we're at it
        if (last_air and !new_air) {
            section.block_count += 1;
        } else if (!last_air and new_air) {
            section.block_count -= 1;
        }

        if (blockIsMotionBlocking(value) and self.motion_blocking.get(x, z) < y + 1)
            self.motion_blocking.set(x, z, y + 1);
        if (blockIsWorldSurface(value) and self.world_surface.get(x, z) < y + 1)
            self.world_surface.set(x, z, y + 1);
    }
    pub fn setBiome(
        self: *Column,
        x: BiomeAxis,
        z: BiomeAxis,
        y: UBiomeY,
        value: Biome.Id,
    ) void {
        if (y >= self.height() >> 2) return;
        self.sections[y >> 2].biomes.set(x, z, @truncate(y), value);
    }
};

pub const HeightMap = struct {
    const Self = @This();

    pub const InnerArray = PackedArray(math.log2_int_ceil(usize, HEIGHT_MAXIMUM), 256, .right);
    pub const ListSpec = serde.PrefixedArray(
        serde.Num(i32, .big),
        serde.Num(u64, .big),
        .{ .max = 256 },
    );
    pub const InnerLengthSpec = ListSpec.SourceSpec;
    pub const InnerListSpec = ListSpec.TargetSpec;

    inner: InnerArray,

    pub const UT = @This();
    pub const E = ListSpec.E;

    pub fn write(writer: *std.Io.Writer, in: UT, ctx: anytype) !void {
        try ListSpec.write(writer, in.inner.constLongSlice(), ctx);
    }
    pub fn read(reader: *std.Io.Reader, out: *UT, ctx: anytype) !void {
        const height = ctx.world.height;

        var len: InnerLengthSpec.UT = undefined;
        try InnerLengthSpec.read(reader, &len, ctx);
        var slice_: []const InnerListSpec.ElemSpec.UT = undefined;
        try InnerListSpec.readWithBuffer(
            reader,
            &slice_,
            out.inner.data[0..len],
            ctx,
        );
        out.inner.bits = math.log2_int_ceil(UBlockY, height + 1);
    }
    pub fn size(self: UT, ctx: anytype) usize {
        return ListSpec.size(self.inner.constLongSlice(), ctx);
    }
    pub fn deinit(self: *UT, _: anytype) void {
        self.* = undefined;
    }

    pub fn set(self: *Self, x: BlockAxis, z: BlockAxis, value: UBlockY) void {
        return self.inner.set(@as(u8, x) + (@as(u8, z) << 4), @intCast(value));
    }
    pub fn get(self: *Self, x: BlockAxis, z: BlockAxis) UBlockY {
        return @intCast(self.inner.get(@as(u8, x) + (@as(u8, z) << 4)));
    }
};
test "heightmap" {
    var m = HeightMap{ .inner = HeightMap.InnerArray.initAll(9, 1) };
    for (0..256) |i|
        m.inner.set(@intCast(i), @intCast(i));
    for (0..256) |i|
        try testing.expectEqual(@as(u9, @intCast(i)), m.inner.get(@intCast(i)));
}

pub const ChunkSection = serde.Struct(struct {
    block_count: serde.Casted(i16, u16),
    blocks: PalettedContainer(.block),
    biomes: PalettedContainer(.biome),
});


pub const BlockAxis = u4;
pub const BiomeAxis = u2;
pub fn AxisIndex(comptime Axis: type) type {
    return @Type(.{ .int = .{
        .signedness = .unsigned,
        .bits = @typeInfo(Axis).int.bits * 3,
    } });
}
pub inline fn axisToIndex(
    comptime Axis: type,
    x: Axis,
    z: Axis,
    y: Axis,
) AxisIndex(Axis) {
    const Index = AxisIndex(Axis);
    const one_shift: comptime_int = @intCast(@typeInfo(Axis).int.bits);
    return (@as(Index, y) << (one_shift * 2)) |
        (@as(Index, z) << one_shift) |
        @as(Index, x);
}

pub fn PalettedContainer(comptime kind: enum { block, biome }) type {
    return union(enum) {
        pub const Count = switch (kind) {
            .block => 4096,
            .biome => 64,
        };
        pub const Index = switch (kind) {
            .block => u12,
            .biome => u6,
        };
        pub const Axis = switch (kind) {
            .block => BlockAxis,
            .biome => BiomeAxis,
        };
        pub const Id = switch (kind) {
            .block => BlockState.Id,
            .biome => Biome.Id,
        };
        pub const IdBits = @as(comptime_int, @intCast(@typeInfo(Id).int.bits));
        pub const IndirectId = switch (kind) {
            .block => u8,
            .biome => u3,
        };
        pub const MaxIndirectBits = switch (kind) {
            .block => 8,
            .biome => 3,
        };
        pub const MaxDirectBits = switch (kind) {
            .block => 16,
            .biome => 8,
        };
        pub const MaxIndirectPaletteLength = math.maxInt(IndirectId) + 1;
        pub const IndirectPaletteLen =
            std.math.IntFittingRange(0, MaxIndirectPaletteLength);

        pub const IndirectData = PackedArray(MaxIndirectBits, Count, .right);
        pub const PaletteData = struct {
            buf: [MaxIndirectPaletteLength]Id = undefined,
            list: std.ArrayListUnmanaged(Id) = undefined,
        };
        pub const DirectData = PackedArray(16, Count, .right);

        single: Id,
        indirect: struct {
            palette: PaletteData,
            data: IndirectData,
        },
        direct: DirectData,

        pub const UT = @This();

        const Self = @This();
        pub fn upgrade(self: *Self) void {
            switch (self.*) {
                .single => |id| self.* = .{
                    .indirect = .{
                        .palette = blk: {
                            var res = PaletteData{};
                            res.list = std.ArrayListUnmanaged(Id).initBuffer(&res.buf);
                            res.list.appendBounded(id) catch unreachable;
                            break :blk res;
                        },
                        .data = IndirectData.init(4),
                    },
                },
                .indirect => |d| {
                    var direct = DirectData.init(IdBits);
                    for (0..Count) |i| {
                        direct.set(
                            @intCast(i),
                            d.palette.list.items[d.data.get(@intCast(i))],
                        );
                    }
                    self.* = .{ .direct = direct };
                },
                else => {},
            }
        }
        pub fn set(self: *Self, x: Axis, z: Axis, y: Axis, value: Id) void {
            const index = axisToIndex(Axis, x, z, y);
            switch (self.*) {
                .single => |id| if (value != id) {
                    self.upgrade(); // upgrade to indirect
                    const palette_id = self.indirect.palette.list.items.len;
                    self.indirect.palette.list.appendAssumeCapacity(value);
                    self.indirect.data.set(index, @intCast(palette_id));
                },
                .indirect => |*d| {
                    const palette_id =
                        for (d.palette.list.items, 0..) |id, i| {
                            if (id == value)
                                break i;
                        } else d.palette.list.items.len;
                    //std.debug.print("value: {}, palette id: {}\n", .{ value, palette_id });
                    if (palette_id == d.palette.list.items.len) {
                        d.palette.list.appendBounded(value) catch {
                            self.upgrade(); // upgrade to direct
                            self.direct.set(index, value);
                            return;
                        };
                        if (d.palette.list.items.len > (@as(usize, 1) << @intCast(d.data.bits))) {
                            d.data.changeBits(d.data.bits + 1);
                        }
                    }
                    d.data.set(index, @intCast(palette_id));
                },
                .direct => |*d| {
                    if (IdBits - @clz(value) > d.bits)
                        d.changeBits(IdBits - @clz(value));
                    d.set(index, value);
                },
            }
        }
        pub fn get(self: Self, x: Axis, z: Axis, y: Axis) Id {
            const index = axisToIndex(Axis, x, z, y);
            return switch (self) {
                .single => |id| id,
                .indirect => |d| d.palette.list.items[@intCast(d.data.get(index))],
                .direct => |d| @intCast(d.get(index)),
            };
        }

        pub fn write(writer: *std.Io.Writer, in: UT, ctx: anytype) !void {
            switch (in) {
                .single => |id| {
                    try writer.writeByte(0);
                    try VarI32.write(writer, @intCast(id), ctx);
                    try VarI32.write(writer, 0, ctx);
                },
                .indirect => |d| {
                    try writer.writeByte(d.data.bits);
                    try VarI32.write(writer, @intCast(d.palette.list.items.len), ctx);
                    for (d.palette.list.items) |item|
                        try VarI32.write(writer, @intCast(item), ctx);
                    const longs = d.data.constLongSlice();
                    try VarI32.write(writer, @intCast(longs.len), ctx);
                    for (longs) |item|
                        try serde.Num(u64, .big).write(writer, item, ctx);
                },
                .direct => |d| {
                    try writer.writeByte(d.bits);
                    const longs = d.constLongSlice();
                    try VarI32.write(writer, @intCast(longs.len), ctx);
                    for (longs) |item|
                        try serde.Num(u64, .big).write(writer, item, ctx);
                },
            }
        }

        pub fn read(reader: *std.Io.Reader, out: *UT, ctx: anytype) !void {
            var bits: u8 = undefined;
            try serde.Num(u8, .big).read(reader, &bits, ctx);
            switch (bits) {
                0 => {
                    out.* = .{ .single = undefined };
                    try serde.Casted(VarI32, Id).read(reader, &out.single, ctx);
                    try serde.Constant(VarI32, 0, null).read(reader, undefined, ctx);
                },
                1...MaxIndirectBits => {
                    out.* = .{ .indirect = .{
                        .palette = pal: {
                            var res = PaletteData{};
                            res.list = .initBuffer(&res.buf);
                            break :pal res;
                        },
                        .data = IndirectData.init(@intCast(bits)),
                    } };
                    try serde.Casted(VarI32, IndirectPaletteLen)
                        .read(reader, @ptrCast(&out.indirect.palette.list.items.len), ctx);
                    for (out.indirect.palette.list.items) |*item|
                        try serde.Casted(VarI32, Id).read(reader, item, ctx);

                    var read_long_len: u32 = undefined;
                    try serde.Casted(VarI32, u32).read(reader, &read_long_len, ctx);
                    for (out.indirect.data.longSlice()) |*item|
                        try serde.Num(u64, .big).read(reader, item, ctx);
                },
                MaxIndirectBits + 1...MaxDirectBits => {
                    var read_long_len: u32 = undefined;
                    try serde.Casted(VarI32, u32).read(reader, &read_long_len, ctx);
                    out.* = .{ .direct = DirectData.init(@intCast(bits)) };
                    for (out.direct.longSlice()) |*item|
                        try serde.Num(u64, .big).read(reader, item, ctx);
                },
                else => return error.InvalidBits,
            }
        }
        pub fn deinit(self: *UT, _: anytype) void {
            self.* = undefined;
        }
        pub fn size(self: UT, ctx: anytype) usize {
            switch (self) {
                .single => |id| return 1 +
                    VarI32.size(@intCast(id), ctx) + VarI32.size(0, ctx),
                .indirect => |d| {
                    const longs = d.data.constLongSlice();
                    var total =
                        1 + VarI32.size(@intCast(d.palette.list.items.len), ctx) +
                        VarI32.size(@intCast(longs.len), ctx);
                    for (d.palette.list.items) |item|
                        total += VarI32.size(@intCast(item), ctx);
                    for (longs) |item|
                        total += serde.Num(u64, .big).size(item, ctx);
                    return total;
                },
                .direct => |d| {
                    const longs = d.constLongSlice();
                    var total = 1 + VarI32.size(@intCast(longs.len), ctx);
                    for (longs) |item| total += serde.Num(u64, .big).size(item, ctx);
                    return total;
                },
            }
        }
    };
}
