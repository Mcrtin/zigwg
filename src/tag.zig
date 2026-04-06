const std = @import("std");
const Block = @import("mc-generated").Block;
pub fn block(comptime tag: anytype) []*const Block {
    const blocks: [tag.values.len]*const Block = undefined;
    for (&blocks, tag.values) |*block_, val|
        block_.* = &@field(Block, @tagName(val));
    return blocks;
}
