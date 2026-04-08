

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
