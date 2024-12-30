/// Some stdout styling
const std = @import("std");
const File = std.fs.File;
const Writer = File.Writer;

const FrameParameters = struct {
    char: u8 = '=',
    horizontal_pad: usize = 2,
    vertical_pad: usize = 1,
};

const CellContent = union(enum) { frame, pad, text: usize };

pub fn frameText(writer: Writer, text: []const u8, parameters: FrameParameters) !void {
    const char = parameters.char;
    const horizontal_pad = parameters.horizontal_pad;
    const vertical_pad = parameters.vertical_pad;

    // computing dimensions
    const width = text.len + 2 * (horizontal_pad + 1);
    const height = 1 + 2 * (vertical_pad + 1);
    const text_starts = 1 + horizontal_pad;
    const text_position = 1 + vertical_pad;
    try writer.writeByte('\n');
    for (0..height) |j| {
        for (0..width) |i| {
            var content: CellContent = CellContent.pad;
            if ((i == width - 1) or (i == 0)) {
                content = CellContent.frame;
            }
            if ((j == height - 1) or (j == 0)) {
                content = CellContent.frame;
            }
            const text_idx: i32 = @as(i32, @intCast(i)) - @as(i32, @intCast(text_starts));
            if ((j == text_position) and (text_idx >= 0) and (text_idx < text.len)) {
                content = CellContent{ .text = @intCast(text_idx) };
            }

            const char_to_draw = switch (content) {
                .pad => ' ',
                .frame => char,
                .text => |*idx| text[idx.*],
            };
            try writer.writeByte(char_to_draw);
        }
        try writer.writeByte('\n');
    }
    try writer.writeByte('\n');
}
