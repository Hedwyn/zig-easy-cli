/// Draws a few tables on stdout, to showcase the table rendering of the styling module
const std = @import("std");
const styling = @import("styling");

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &buf);
    const out = &file_writer.interface;

    const headers = [_][]const u8{ "Package", "Version", "Size (KB)", "Status" };
    const rows = [_][]const []const u8{
        &.{ "zig-easy-cli", "0.4.1", "128", "installed" },
        &.{ "libcurl", "8.10.1", "2048", "up to date" },
        &.{ "café-utils", "1.0.0", "64", "outdated" },
        &.{ "tiny", "0.0.1", "1" },
    };

    // Default look: rounded borders, left-aligned
    try styling.writeTable(out, &headers, &rows, .{
        .alignments = &.{ .left, .center, .right, .left },
    });

    // Other border styles
    inline for (.{ .light, .heavy, .double, .ascii }) |border| {
        try out.print("\n{s}:\n", .{@tagName(border)});
        try styling.writeTable(out, &headers, &rows, .{
            .border = border,
            .alignments = &.{ .left, .center, .right, .left },
        });
    }

    // A rule between every row, and a width limit that truncates cells
    try out.writeAll("\nrow separators, max width 40:\n");
    try styling.writeTable(out, &headers, &rows, .{
        .row_separators = true,
        .max_width = 40,
    });

    // Colored through a palette
    try out.writeAll("\nstyled with the \"clay\" palette:\n");
    const rich: styling.RichWriter = .{
        .writer = out,
        .palette = styling.palettes.get("clay").?,
    };
    rich.table(&headers, &rows, .{ .alignments = &.{ .left, .center, .right, .left } });

    try out.flush();
}
