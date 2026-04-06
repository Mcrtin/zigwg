const std = @import("std");
const mcg = @import("mc-generated");
pub fn instance(comptime block: *const mcg.Block, comptime properties: Properties(block)) mcg.Block.Instance {
    var res: @typeInfo(mcg.Block.Instance).@"enum".tag_type = 0;
    inline for (properties) |property| {
        switch (@typeInfo(@TypeOf(property))) {
            .@"enum" => |e| {
                res *= e.fields.len;
                res += @intFromEnum(property);
            },
            .bool => {
                res *= 2;
                res += @intFromBool(property);
            },
            else => comptime unreachable,
        }
    }
    return @enumFromInt(res + @intFromEnum(block.first_instance));
}

fn Properties(comptime block: *const mcg.Block) type {
    var types: [block.properties.len]type = undefined;
    for (&types, block.properties) |*t, property|
        t.* = @FieldType(mcg.Block.Property, @tagName(property));

    return std.meta.Tuple(&types);
}
