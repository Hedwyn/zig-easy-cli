const std = @import("std");
const File = std.fs.File;
const Writer = File.Writer;

const FrameParameters = struct {
    char: u8 = '=',
    horizontal_pad: usize = 2,
    vertical_pad: usize = 1,
};

pub fn repeatChar(writer: Writer, char: u8, repetitions: usize) usize {
    for (0..repetitions) |_| {
        writer.writeByte(char) catch unreachable;
    }
    return repetitions;
}

fn writeFrameLine(writer: Writer, line: []const u8, char: u8, pad: usize) !usize {
    var char_ctr: usize = 0;
    char_ctr += 1;
    try writer.writeByte(char);
    for (0..pad) |_| {
        try writer.writeByte(' ');
    }
    char_ctr += pad;

    char_ctr += try writer.write(line);
    for (0..pad) |_| {
        try writer.writeByte(' ');
    }
    char_ctr += pad;
    try writer.writeByte('\n');
    char_ctr += 1;
    return char_ctr;
}

fn _writePadLine(writer: Writer, length: usize, char: u8) !usize {
    if (length < 2) {
        @panic("Lenght should be at least 2");
    }
    var char_ctr: usize = 0;
    try writer.writeByte(char);
    char_ctr += 1;
    for (0..length - 2) |_| {
        try writer.writeByte(' ');
    }
    char_ctr += (length - 2);
    try writer.writeByte(char);
    char_ctr += 1;
    try writer.writeByte('\n');
    char_ctr += 1;

    return char_ctr;
}

fn writePadLine(writer: Writer, length: usize, char: u8) usize {
    return (_writePadLine(writer, length, char) catch unreachable);
}

pub fn frameText(writer: Writer, text: []const u8, parameters: FrameParameters) !usize {
    const char = parameters.char;
    const horizontal_pad = parameters.horizontal_pad;
    const vertical_pad = parameters.vertical_pad;
    var char_ctr: usize = 0;

    // computing dimensions
    const width = text.len + 2 * (horizontal_pad + 1);
    // const height = 1 + (vertical_pad + 1);

    // drawing top/bottom line
    char_ctr += repeatChar(writer, char, width);
    defer char_ctr += repeatChar(writer, char, width);
    // drawing pad lines
    for (0..vertical_pad) |_| {
        char_ctr += writePadLine(writer, width, char);
        defer char_ctr += writePadLine(writer, width, char);
        try writer.writeByte('\n');
    }
    char_ctr += try writeFrameLine(writer, text, char, horizontal_pad);
    try writer.writeByte('\n');
    return char_ctr;
}

test "generate frame" {
    const text = "Hello World !";
    const writer = std.io.getStdOut().writer();

    _ = try frameText(writer, text, .{});
    // std.debug.print("{s}\n", .{frameText(text, .{})});
}
