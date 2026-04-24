const mcg = @import("mc-generated");
const zigwg = @import("zigwg");
const rng = @import("rng.zig");
const meta = @import("meta.zig");
const math = @import("math.zig");
const nbt = @import("nbt");
const std = @import("std");
pub const paletted = @import("paletted_container.zig");

pub const PalettedContainer = paletted.PalettedContainer;

pub fn main(init: std.process.Init) !void {
    const settings = mcg.worldgen.noise_settings.@"minecraft:overworld";
    const seed = 1;
    const chunk = @import("generator.zig").gen(settings, seed);
    var sections: [@divExact(settings.noise.height, 16)]Section = undefined;
    for (&sections, chunk, 0..) |*section, paletted_container, i|
        section.* = .{
            .block_states = paletted_container,
            .BlockLight = null,
            .SkyLight = null,
            .Y = @as(i8, @intCast(i)) + @as(i8, @intCast(@divExact(settings.noise.min_y, 16))),
            .biomes = null,
        };

    try gen(init.io, &sections, "r.0.0.mca");
}

fn gen(io: std.Io, chunk: []const Section, path: []const u8) !void {
    var f2 = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f2.close(io);
    var wbuf: [1024]u8 = undefined;
    var w = f2.writer(io, &wbuf);
    defer w.interface.flush() catch {};
    try writeChunk(io, &w, 0, 0, @as(InnerChunk, .{
        .Status = .@"minecraft:full",
        .zPos = @as(i32, 0),
        .block_entities = &.{},
        .yPos = @as(i32, -64),
        .LastUpdate = @as(i64, 0),
        .structures = .{ .references = .empty, .starts = .empty },
        .InhabitedTime = @as(i64, 0),
        .xPos = @as(i32, 0),
        .Heightmaps = .{
            .MOTION_BLOCKING = null,
            .MOTION_BLOCKING_NO_LEAVES = null,
            .OCEAN_FLOOR = null,
            .OCEAN_FLOOR_WG = null,
            .WORLD_SURFACE = null,
            .WORLD_SURFACE_WG = null,
        },
        .sections = chunk,
        .block_ticks = &.{},
        .DataVersion = @as(i64, 4440),
        .fluid_ticks = &.{},
        .isLightOn = false,
    }));
}

fn writeChunk(
    io: std.Io,
    w: *std.Io.File.Writer,
    chunk_x: u5,
    chunk_z: u5,
    // offset: u24,
    chunk: anytype,
) !void {
    const index = (@as(usize, chunk_z) * (std.math.maxInt(u5) + 1) + @as(usize, chunk_x)) * @sizeOf(u32);
    try w.seekTo(index);

    const offset = 2;
    try w.interface.writeInt(u24, offset, .big);
    try w.interface.flush();

    try w.seekTo(SECTOR_BYTES + index);
    try w.interface.writeInt(i32, @intCast(std.Io.Clock.real.now(io).toSeconds()), .big);
    try w.interface.flush();
    try w.seekTo(@as(usize, offset) * SECTOR_BYTES + @sizeOf(i32) + @sizeOf(Compression));

    try nbt.write(&w.interface, chunk, true);

    try w.interface.flush();
    const length = w.pos - (@as(u64, offset) * SECTOR_BYTES + @sizeOf(i32));
    const len = std.math.divCeil(u64, length, SECTOR_BYTES) catch unreachable;
    try w.interface.splatByteAll(0, len * SECTOR_BYTES - length - @sizeOf(i32));
    try w.interface.flush();
    try w.seekTo(index + 3);
    try w.interface.writeInt(u8, @intCast(len), .big);
    try w.interface.flush();
    std.debug.print("length: {d}, len: {d}\n", .{ length, len });
    try w.seekTo(@as(usize, offset) * SECTOR_BYTES);
    std.debug.assert(length <= @as(usize, len) * SECTOR_BYTES);
    std.debug.assert(length > @as(usize, len - 1) * SECTOR_BYTES);
    try w.interface.writeInt(u32, @intCast(length), .big);
    try w.interface.writeInt(u8, @intFromEnum(Compression.none), .big);
    try w.interface.flush();
}
const Heightmap = enum {
    MOTION_BLOCKING,
    MOTION_BLOCKING_NO_LEAVES,
    OCEAN_FLOOR,
    OCEAN_FLOOR_WG,
    WORLD_SURFACE,
    WORLD_SURFACE_WG,
};
const Status = enum {
    pub const is_string = {};
    @"minecraft:empty",
    @"minecraft:structure_starts",
    @"minecraft:structure_references",
    @"minecraft:biomes",
    @"minecraft:noise",
    @"minecraft:surface",
    @"minecraft:carvers",
    @"minecraft:liquid_carvers",
    @"minecraft:features",
    @"minecraft:light",
    @"minecraft:initialize_light",
    @"minecraft:spawn",
    @"minecraft:full",
};

const BlockEntity = struct {
    id: []const u8,
    keepPacked: ?bool,
    x: i32,
    y: i32,
    z: i32,
    components: std.StringArrayHashMapUnmanaged(nbt.Value) = .empty,
    @"trailing\n": std.StringArrayHashMapUnmanaged(nbt.Value),
};
const Section = struct {
    block_states: PalettedContainer(.block),
    biomes: ?struct { palette: [][]const u8, data: ?[]i64 } = null,
    BlockLight: ?[2048]i8 = null,
    SkyLight: ?[2048]i8 = null,
    Y: i8,
};

const Entity = struct {
    Air: i16,
    CustomName: ?nbt.Value,
    CustomNameVisible: ?bool,
    data: ?std.StringArrayHashMapUnmanaged(nbt.Value),
    fall_distance: f64,
    Fire: i16,
    Glowing: ?bool,
    HasVisualFire: ?bool,
    id: []const u8,
    Invulnerable: bool,
    Motion: [3]f64,
    NoGravity: ?bool,
    OnGround: bool,
    Passengers: ?[]@This(),
    PortalCooldown: i32,
    Pos: [3]f64,
    Rotation: [2]f32,
    Silent: ?bool,
    Tags: ?[][]const u8,
    TicksFrozen: ?i32,
    UUID: [4]u32,

    @"trailing\n": std.StringArrayHashMapUnmanaged(nbt.Value),
};
const CarvingInnerProtoChunk = struct {
    xPos: i32,
    yPos: i32,
    zPos: i32,
    block_entities: []BlockEntity,
    LastUpdate: i64,
    structures: Structures,
    InhabitedTime: i64,
    Heightmaps: std.enums.EnumFieldStruct(Heightmap, ?[]i64, null),
    sections: []Section,
    entities: []Entity,
    block_ticks: []TileTick,
    carving_mask: []i64,
    PostProcessing: [24][]i16 = @splat(&.{}),
    DataVersion: i32,
    fluid_ticks: []TileTick,
};
const InnerProtoChunk = struct {
    xPos: i32,
    yPos: i32,
    zPos: i32,
    block_entities: []BlockEntity,
    LastUpdate: i64,
    structures: Structures,
    InhabitedTime: i64,
    Heightmaps: std.enums.EnumFieldStruct(Heightmap, ?[]i64, null),
    sections: []Section,
    entities: []Entity,
    block_ticks: []TileTick,
    PostProcessing: [24][]i16 = @splat(&.{}),
    DataVersion: i32,
    fluid_ticks: []TileTick,
};

const BlockState = struct {
    Name: []const u8,
    Properties: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
};

const Structures = struct {
    references: std.StringArrayHashMapUnmanaged([]packed struct { x: i32, z: i32 }),
    starts: std.StringArrayHashMapUnmanaged(struct {
        Children: ?[]struct {
            BB: [6]i32,
            O: i32,
            id: []const u8,
            GD: i32,
            @"trailing\n": std.StringArrayHashMapUnmanaged(nbt.Value),
        },
        ChunkX: ?i32,
        ChunkZ: ?i32,
        id: []const u8,
        Processed: ?[]struct { X: i32, Z: i32 },
        references: ?i32,
    }),
};
const TileTick = struct {
    i: []const u8,
    p: i32,
    t: i32,
    x: i32,
    y: i32,
    z: i32,
};
const InnerChunk = struct {
    Status: Status,
    xPos: i32,
    yPos: i32,
    zPos: i32,
    LastUpdate: i64,
    block_entities: []const BlockEntity,
    structures: Structures,
    InhabitedTime: i64,
    Heightmaps: std.enums.EnumFieldStruct(Heightmap, ?[]const i64, null),
    sections: []const Section,
    block_ticks: []const TileTick,
    isLightOn: bool,
    PostProcessing: [24][]const i16 = @splat(&.{}),
    DataVersion: i32,
    fluid_ticks: []const TileTick,
};
const SECTOR_BYTES = 4 << 10;

const Compression = enum(u8) {
    gzip = 1,
    zlib = 2,
    none = 3,
    lz4 = 4,
    custom = 127,
};

test "main" {
    // _ = paletted;
    _ = @import("rng.zig");
    _ = @import("noise.zig");
}
