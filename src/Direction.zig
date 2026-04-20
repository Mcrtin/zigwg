const Pos = @import("position.zig");
pub const Axis = enum {
    X,
    Y,
    Z,
};
pub const Sign = enum {
    Positive,
    Negative,
};

axis: Axis,
sign: Sign,

pub const up: @This() = .init(.Y, .Positive);
pub const down: @This() = .init(.Y, .Negative);
pub const south: @This() = .init(.Z, .Positive);
pub const north: @This() = .init(.Z, .Negative);
pub const east: @This() = .init(.X, .Positive);
pub const west: @This() = .init(.X, .Negative);

pub fn init(axis: Axis, sign: Sign) @This() {
    return .{ .axis = axis, .sign = sign };
}

pub fn toPos(self: @This()) Pos.Block {
    const unit = switch (self.sign) {
        .Negative => -1,
        .Positive => 1,
    };
    return switch (self.axis) {
        .X => .init(unit, 0, 0),
        .Y => .init(0, unit, 0),
        .Z => .init(0, 0, unit),
    };
}
