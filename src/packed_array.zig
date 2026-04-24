const std = @import("std");
pub fn PackedArray(
    comptime max_bits: u16,
    comptime count: usize,
    comptime aligned: enum { left, right },
) type {
    return struct {
        const Self = @This();

        pub const PackedType = u64;
        pub const Index = std.math.IntFittingRange(0, count - 1);
        pub const MaxLongCount =
            std.math.divCeil(usize, count, @divTrunc(64, @as(usize, max_bits))) catch unreachable;
        pub const Bits = std.math.IntFittingRange(0, max_bits);
        pub const Value = @Int(.unsigned, max_bits);
        pub const LongIndex = std.math.IntFittingRange(0, MaxLongCount - 1);
        const ShiftInt = std.math.Log2Int(u64);

        bits: Bits,
        data: [MaxLongCount]u64,

        pub fn init(bits: Bits) Self {
            return .{ .bits = bits, .data = @splat(0) };
        }

        pub fn initAll(bits: Bits, value: Value) Self {
            return .{ .bits = bits, .data = @splat(value) };
        }

        pub fn longCount(bits: Bits) std.math.IntFittingRange(0, MaxLongCount) {
            return @intCast(
                std.math.divCeil(usize, count, @divTrunc(64, @as(usize, bits))) catch
                    unreachable,
            );
        }
        pub fn longSlice(self: *Self) []u64 {
            return self.data[0..Self.longCount(self.bits)];
        }
        pub fn constLongSlice(self: *const Self) []const u64 {
            return self.data[0..Self.longCount(self.bits)];
        }
        pub inline fn longIndex(bits: Bits, index: Index) LongIndex {
            return @intCast(@as(usize, index) / (64 / @as(usize, bits)));
        }
        pub inline fn lowIndex(bits: Bits, index: Index) ShiftInt {
            return @intCast(@as(usize, index) % (64 / @as(usize, bits)));
        }
        pub inline fn getShift(bits: Bits, index: Index) ShiftInt {
            return @intCast(lowIndex(bits, index) * bits + switch (aligned) {
                .left => @as(ShiftInt, @truncate(@as(std.math.Log2IntCeil(u64), 64) % bits)),
                .right => 0,
            });
        }

        pub fn set(self: *Self, index: Index, value: Value) void {
            return self.setInArray(self.bits, index, value);
        }

        pub inline fn setInArray(
            self: *Self,
            bits: Bits,
            index: Index,
            value: Value,
        ) void {
            const shift = getShift(bits, index);
            const mask = ~(~@as(u64, 0) << @as(ShiftInt, @intCast(bits)));
            const long_index = longIndex(bits, index);
            self.data[long_index] &= ~(mask << shift);
            self.data[long_index] |= @as(u64, value) << shift;
        }

        pub fn get(self: *const Self, index: Index) Value {
            return self.getInArray(self.bits, index);
        }

        pub inline fn getInArray(
            self: *const Self,
            bits: Bits,
            index: Index,
        ) Value {
            const shift = getShift(bits, index);
            const mask = ~(~@as(u64, 0) << @as(ShiftInt, @intCast(bits)));
            return @intCast(
                (self.data[longIndex(bits, index)] >> shift) & mask,
            );
        }

        pub fn changeBits(self: *Self, target_bits: Bits) void {
            std.debug.assert(target_bits <= max_bits);
            if (target_bits > self.bits) {
                var i: Index = count - 1;
                while (true) {
                    const val = self.getInArray(self.bits, i);
                    self.setInArray(target_bits, i, val);
                    if (i == 0) break;
                    i -= 1;
                }
            } else {
                var i: Index = 0;
                while (true) {
                    const val = self.getInArray(self.bits, i);
                    self.setInArray(self.bits, i, 0);
                    self.setInArray(target_bits, i, val);
                    if (i == count - 1) break;
                    i += 1;
                }
            }
            self.bits = target_bits;
        }
    };
}

test "packed array" {
    const Arr = PackedArray(16, 4096, .right);
    var arr = Arr.init(15);
    for (0..4096) |i| {
        arr.set(@intCast(i), @intCast(i));
    }
    for (0..4096) |i| {
        try std.testing.expectEqual(@as(Arr.Value, @intCast(i)), arr.get(@intCast(i)));
    }
    arr.changeBits(16);
    for (0..4096) |i| {
        try std.testing.expectEqual(@as(Arr.Value, @intCast(i)), arr.get(@intCast(i)));
    }
    for (0..4096) |i| {
        arr.set(@intCast(i), @intCast(i));
    }
    for (0..4096) |i| {
        try std.testing.expectEqual(@as(Arr.Value, @intCast(i)), arr.get(@intCast(i)));
    }
    arr.changeBits(12);
    for (0..4096) |i| {
        try std.testing.expectEqual(@as(Arr.Value, @intCast(i)), arr.get(@intCast(i)));
    }
    for (0..4096) |i| {
        arr.set(@intCast(i), @intCast(i));
    }
    for (0..4096) |i| {
        try std.testing.expectEqual(@as(Arr.Value, @intCast(i)), arr.get(@intCast(i)));
    }
}
