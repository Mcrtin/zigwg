const std = @import("std");

pub fn Lazy(comptime function: anytype) type {
    const function_info = @typeInfo(@TypeOf(function)).@"fn";
    std.debug.assert(function_info.params.len == 1);
    const Context = function_info.params[0];
    const T = function_info.return_type.?;
    return struct {
        context: Context,
        res: ?T,
        pub fn init(context: Context) @This() {
            return .{ .context = context };
        }

        pub fn get(self: *@This()) T {
            return self.res orelse {
                self.res = function(self.context);
                return self.res.?;
            };
        }
    };
}
