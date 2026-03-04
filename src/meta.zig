const std = @import("std");

pub fn fromData(T: type, data: anytype) T {
    var res: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field|
        @field(res, field.name) = if (@hasField(@TypeOf(data), field.name))
            @field(data, field.name)
        else
            field.defaultValue().?;
    return res;
}

fn registeredType(comptime registry: type, comptime name: []const u8) type {
    comptime {
        if (!std.mem.startsWith(u8, name, "minecraft:")) @compileError("unsupported string " ++ name);

        var it = std.mem.splitScalar(u8, name["minecraft:".len..], '/');

        var v = registry;
        var i = it.index.?;
        while (it.next()) |s| : (i = it.index.?) {
            if (it.peek() == null)
                return @TypeOf(@field(v, s))
            else
                v = @field(v, it.buffer[i..it.index.?]);
        }
        unreachable;
    }
}
pub fn getFromRegistry(comptime registry: type, comptime name: []const u8) registeredType(registry, name) {
    comptime {
        if (!std.mem.startsWith(u8, name, "minecraft:")) @compileError("unsupported string " ++ name);

        var it = std.mem.splitScalar(u8, name["minecraft:".len..], '/');

        var v = registry;
        var i = it.index.?;
        while (it.next()) |s| : (i = it.index.?) {
            if (it.peek() == null)
                return @field(v, s)
            else
                v = @field(v, it.buffer[i..it.index.?]);
        }
        unreachable;
    }
}

pub fn getFromRegistryT(T: type, comptime registry: type, comptime name: []const u8) T {
    comptime {
        if (!std.mem.startsWith(u8, name, "minecraft:")) @compileError("unsupported string " ++ name);

        var it = std.mem.splitScalar(u8, name["minecraft:".len..], '/');

        var v = registry;
        var i = it.index.?;
        while (it.next()) |s| : (i = it.index.?) {
            if (it.peek() == null)
                return @field(v, s)
            else
                v = @field(v, it.buffer[i..it.index.?]);
        }
        unreachable;
    }
}
