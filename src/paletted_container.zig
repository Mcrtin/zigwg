const std = @import("std");
const mcg = @import("mc-generated");
const nbt = @import("nbt");
const Pos = @import("position.zig");
pub const BiomeId = enum(std.math.IntFittingRange(0, @typeInfo(mcg.worldgen.biome).@"struct".decls.len - 3)) {
    _,

    const idToBiome = blk: {
        const decls = @typeInfo(mcg.worldgen.biome).@"struct".decls[2..];
        var res: [decls.len]*const mcg.worldgen.biome = undefined;
        for (&res, decls) |*v, decl| {
            v.* = &@field(mcg.worldgen.biome, decl.name);
        }
        break :blk res;
    };

    pub fn biome(self: @This()) mcg.worldgen.biome {
        return idToBiome[@intFromEnum(self)];
    }

    pub fn name(self: @This()) []const u8 {
        const decls = @typeInfo(mcg.worldgen.biome).@"struct".decls[2..];
        return decls[@intFromEnum(self)].name;
    }
};

const PackedArray = @import("packed_array.zig").PackedArray;

pub fn PalettedContainer(comptime kind: enum { block, biome }) type {
    return union(enum) {
        pub const Count = 1 << @bitSizeOf(Position);
        pub const Position = switch (kind) {
            .block => Pos.Section.Block,
            .biome => packed struct { x: u2, y: u2, z: u2 },
        };
        pub const Id = switch (kind) {
            .block => mcg.Block.Instance,
            .biome => BiomeId,
        };
        pub const IndirectId = switch (kind) {
            .block => u8,
            .biome => u3,
        };
        pub const MaxIndirectBits = switch (kind) {
            .block => 8,
            .biome => 3,
        };
        pub const MaxIndirectPaletteLength = std.math.maxInt(IndirectId) + 1;
        pub const IndirectPaletteLen =
            std.math.IntFittingRange(0, MaxIndirectPaletteLength);

        pub const IndirectData = PackedArray(MaxIndirectBits, Count, .right);
        pub const PaletteData = struct {
            buf: [MaxIndirectPaletteLength]Id = undefined,
            list: std.ArrayListUnmanaged(Id) = .empty,
        };
        pub const DirectData = PackedArray(@bitSizeOf(Id), Count, .right);
        const min_bits = 4;

        single: Id,
        indirect: struct {
            palette: PaletteData = .{},
            data: IndirectData = .init(min_bits),
        },
        direct: DirectData,

        const Self = @This();
        pub fn upgrade(self: *Self) void {
            switch (self.*) {
                .single => |id| {
                    self.* = .{ .indirect = .{} };
                    self.indirect.palette.list = .initBuffer(&self.indirect.palette.buf);
                    self.indirect.palette.list.appendAssumeCapacity(id);
                },
                .indirect => |d| {
                    var direct = DirectData.init(@bitSizeOf(Id));
                    for (0..Count) |i| {
                        direct.set(
                            @intCast(i),
                            @intFromEnum(d.palette.list.items[d.data.get(@intCast(i))]),
                        );
                    }
                    self.* = .{ .direct = direct };
                },
                else => {},
            }
        }
        pub fn set(self: *Self, pos: Position, value: Id) void {
            switch (self.*) {
                .single => |id| if (value != id) {
                    self.upgrade(); // upgrade to indirect
                    self.set(pos, value);
                },
                .indirect => |*d| {
                    const palette_id = if (std.mem.indexOfScalar(Id, d.palette.list.items, value)) |id|
                        id
                    else blk: {
                        d.palette.list.appendBounded(value) catch {
                            self.upgrade(); // upgrade to direct
                            self.set(pos, value);
                            return;
                        };
                        if (d.palette.list.items.len > (@as(usize, 1) << @intCast(d.data.bits)))
                            d.data.changeBits(d.data.bits + 1);
                        break :blk d.palette.list.items.len - 1;
                    };
                    d.data.set(@bitCast(pos), @intCast(palette_id));
                },
                .direct => |*d| d.set(@bitCast(pos), @intFromEnum(value)),
            }
        }
        pub fn get(self: Self, pos: Position) Id {
            return switch (self) {
                .single => |id| id,
                .indirect => |d| d.palette.list.items[@intCast(d.data.get(@bitCast(pos)))],
                .direct => |d| @intCast(d.get(@bitCast(pos))),
            };
        }

        pub const defaultNbtType = .Compound;
        pub fn writeNbt(self: *const @This(), w: nbt.Writer) !void {
            switch (self.*) {
                .single => |id| {
                    try writePalette(w, &.{id});
                },
                .indirect => |d| {
                    try writePalette(w, d.palette.list.items);
                    try w.writeTagType(.LongArray);
                    try w.writeString("data");
                    const slice = @constCast(&d).data.longSlice();
                    try w.writeLen(@intCast(slice.len));
                    try w.writer.writeSliceEndian(u64, slice, .big);
                },
                .direct => |d| {
                    try w.writeTagType(.LongArray);
                    try w.writeString("data");
                    const slice = @constCast(&d).longSlice();
                    try w.writeLen(@intCast(slice.len));
                    try w.writer.writeSliceEndian(u64, slice, .big);
                    try w.writeString("palette");
                    @panic("TODO");
                },
            }
            try w.writeTagType(.End);
        }

        fn writePalette(w: nbt.Writer, palette: []const Id) !void {
            try w.writeTagType(.List);
            try w.writeString("palette");
            try w.writeTagType(.Compound);
            try w.writeLen(@intCast(palette.len));
            for (palette) |palette_entry|
                switch (kind) {
                    .block => {
                        const id: mcg.Block.Instance = palette_entry;
                        try w.writeTagType(.String);
                        try w.writeString("Name");
                        try w.writeString(id.block().name);
                        for (id.block().properties, 0..) |property, idx| {
                            try w.writeTagType(.String);
                            try w.writeString(@tagName(property));
                            switch (id.getIthProperty(idx).?) {
                                inline else => |p| {
                                    switch (@typeInfo(@TypeOf(p))) {
                                        .bool => if (p) try w.writeString("true") else try w.writeString("false"),
                                        .@"enum" => try w.writeString(@tagName(p)),
                                        else => comptime unreachable,
                                    }
                                },
                            }
                        }
                        try w.writeTagType(.End);
                    },
                    .biome => try w.writeString(palette_entry.name()),
                };
        }
    };
}

test "paletted nbt single" {
    var b1: [1024]u8 = undefined;

    var w1 = std.Io.Writer.fixed(&b1);
    var b2: [5024]u8 = undefined;

    var w2 = std.Io.Writer.fixed(&b2);
    const BlockState = struct {
        Name: []const u8,
        Properties: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    };
    try nbt.write(&w1, @as(struct {
        data: ?[]i64,
        palette: []const BlockState,
    }, .{
        .data = null,
        .palette = &.{
            .{
                .Name = "minecraft:stone",
                .Properties = .empty,
            },
        },
    }), true);

    var palette = @as(PalettedContainer(.block), .{ .single = @import("block.zig").instance(&mcg.Block.@"minecraft:stone", .{}) });
    palette.set(.init(0, 0, 0), mcg.Block.@"minecraft:cave_air".default_instance);
    try nbt.write(&w2, palette, true);
    try w1.flush();
    try w2.flush();
    try std.testing.expectEqualSlices(u8, w1.buffered(), w2.buffered());
    return error.Test;
}
