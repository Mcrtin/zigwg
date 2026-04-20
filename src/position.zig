const std = @import("std");
const Direction = @import("Direction.zig");

pub const Y = i12;
pub const Height = u11;
pub const XZ = i26;

pub const position = @This();

pub const Column = packed struct {
    x: XZ,
    z: XZ,

    pub fn init(x: XZ, z: XZ) @This() {
        return .{ .x = x, .z = z };
    }

    pub fn block(self: @This(), y: Y) Block {
        return .{ .column = self, .y = y };
    }

    pub fn chunk(self: @This()) Chunk {
        return .{ .x = @intCast(@divFloor(self.x, Chunk.Resolution)), .z = @intCast(@divFloor(self.z, Chunk.Resolution)) };
    }

    pub fn chunkColumn(self: @This()) Chunk.Column {
        return .{ .x = @intCast(@mod(self.x, Chunk.Resolution)), .z = @intCast(@mod(self.z, Chunk.Resolution)) };
    }
};

pub const Block = packed struct {
    column: Column,
    y: Y,

    pub fn init(x: XZ, y: Y, z: XZ) @This() {
        return .{ .column = .init(x, z), .y = y };
    }

    pub fn section(self: @This()) Section {
        return .{ .chunk = self.column.chunk(), .y = @intCast(@divFloor(self.y, Chunk.Resolution)) };
    }

    pub fn chunkBlock(self: @This()) Chunk.Block {
        return .{ .column = self.column.chunkColumn(), .y = self.y };
    }

    pub fn sectionBlock(self: @This()) Section.Block {
        return .{ .column = self.column.chunkColumn(), .y = @intCast(@mod(self.y, Chunk.Resolution)) };
    }

    pub fn distanceSquared(self: @This(), other: @This()) i64 {
        const x: i64 = @as(i27, self.column.x) - @as(i27, other.column.x);
        const z: i64 = @as(i27, self.column.z) - @as(i27, other.column.z);
        const y: i64 = @as(i13, self.y) - @as(i13, other.y);
        return x * x + y * y + z * z;
    }
    pub fn sub(self: @This(), other: @This()) !@This() {
        return .{ .column = .init(
            try std.math.sub(XZ, self.column.x, other.column.x),
            try std.math.sub(XZ, self.column.z, other.column.z),
        ), .y = try std.math.sub(Y, self.y, other.y) };
    }

    pub fn add(self: @This(), other: @This()) !@This() {
        return .{ .column = .init(
            try std.math.add(XZ, self.column.x, other.column.x),
            try std.math.add(XZ, self.column.z, other.column.z),
        ), .y = try std.math.add(Y, self.y, other.y) };
    }

    pub fn move(self: @This(), direction: Direction, count: Y) !@This() {
        return self.add(.init(direction.toPos().mul(.init(count, count, count)) catch unreachable));
    }

    pub fn mul(self: @This(), other: @This()) !@This() {
        return .{ .column = .init(
            try std.math.mul(XZ, self.column.x, other.column.x),
            try std.math.mul(XZ, self.column.z, other.column.z),
        ), .y = try std.math.mul(Y, self.y, other.y) };
    }
};

pub const Section = packed struct {
    pub const Y = i8;
    chunk: Chunk,
    y: @This().Y,
    pub fn block(self: @This(), pos: @This().Block) position.Block {
        return .{ .column = self.chunk.column(pos.column), .y = @as(position.Y, self.y) * Chunk.Resolution + @as(position.Y, pos.y) };
    }
    pub const Block = packed struct {
        column: Chunk.Column,
        y: Chunk.Offset,

        pub fn init(x: Chunk.Offset, y: Chunk.Offset, z: Chunk.Offset) @This() {
            return .{ .column = .init(x, z), .y = y };
        }
    };
};

pub const Chunk = packed struct {
    pub const Resolution = 16;
    pub const Offset = std.math.IntFittingRange(0, Resolution - 1);
    pub const XZ = i22;
    x: @This().XZ,
    z: @This().XZ,

    pub fn init(x: @This().XZ, z: @This().XZ) @This() {
        return .{ .x = x, .z = z };
    }

    pub fn column(self: @This(), pos: @This().Column) position.Column {
        return .{ .x = @as(position.XZ, self.x * Resolution) + @as(position.XZ, pos.x), .z = @as(position.XZ, self.z * Resolution) + @as(position.XZ, pos.z) };
    }

    pub fn block(self: @This(), pos: @This().Block) position.Block {
        return .{ .column = self.column(pos.column), .y = pos.y };
    }

    pub fn section(self: @This(), y: Section.Y) Section {
        return .{ .chunk = self, .y = y };
    }

    pub fn center(self: @This()) position.Column {
        return self.column(.init(8, 8));
    }

    pub fn origin(self: @This()) position.Column {
        return self.column(.init(0, 0));
    }

    pub const Column = packed struct {
        x: Offset,
        z: Offset,

        pub fn init(x: Offset, z: Offset) @This() {
            return .{ .x = x, .z = z };
        }

        pub fn sectionBlock(self: @This(), y: Offset) Section.Block {
            return .{ .column = self, .y = y };
        }

        pub fn block(self: @This(), y: Y) Chunk.Block {
            return .{ .column = self, .y = y };
        }
    };

    pub const Block = packed struct {
        column: Chunk.Column,
        y: Y,

        pub fn init(x: Offset, y: Y, z: Offset) @This() {
            return .{ .column = .init(x, z), .y = y };
        }

        pub fn sectionBlock(self: @This()) Section.Block {
            return .{ .x = self.column.x, .y = @intCast(self.y % Chunk.Resolution), .z = self.column.z };
        }
    };
};
