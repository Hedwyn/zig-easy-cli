/// Some stdout styling
const std = @import("std");
const File = std.fs.File;
const Writer = File.Writer;
const NullWriter = std.io.NullWriter;

const WriteError = File.WriteError;
const panic = std.debug.panic;

const esc = "\u{001b}";

// Text colors (= their background counterpart - 10)
pub const black = esc ++ "[30m";

// Background colors (= their text counterpart + 10)
pub const green_bg = esc ++ "[42m";
pub const clay_bg = esc ++ "[48;5;172m";
pub const blue_bg = esc ++ "[44m";
pub const cyan_bg = esc ++ "[46m";
pub const yellow_bg = esc ++ "[43m";

const bold = esc ++ "[1m";
const dim = esc ++ "[2m";
const italic = esc ++ "[3m";
const underline = esc ++ "[4m";

const reset = esc ++ "[0m";

const max_ansi_color_code_len = 16;
const AnsiColorCodes = enum(u16) {
    black = 30,
    red,
    green,
    yellow,
    blue,
    lagenta,
    cyan,
    white,
    default,

    // 256 bits colors below
    // Adding a 256 bits offset to differentiate from
    // base colors
    dark_green = 256 + 22,
    clay = 256 + 172,
    turquoise = 256 + 29,

    pub fn asText(self: AnsiColorCodes) []const u8 {
        const _info = @typeInfo(AnsiColorCodes).@"enum";
        inline for (_info.field_values) |field_value| {
            const is_256bits = field_value >= 0xFF;
            const fmt = comptime if (is_256bits) "[38;5;{}m" else "[{}m";
            const value = comptime if (is_256bits) field_value & 0xFF else field_value;

            const code = comptime blk: {
                var buf: [max_ansi_color_code_len]u8 = undefined;
                break :blk std.fmt.bufPrint(
                    &buf,
                    fmt,
                    .{value},
                ) catch panic(
                    "Internal error: buffer size for ANSI color codes it too small when text code {any}",
                    .{self},
                );
            };
            if (field_value == @intFromEnum(self)) {
                return esc ++ code;
            }
        }
        unreachable;
    }

    pub fn asBackground(self: AnsiColorCodes) []const u8 {
        const _info = @typeInfo(AnsiColorCodes).@"enum";
        inline for (_info.field_values) |field_value| {
            const is_256bits = field_value >= 0xFF;
            const fmt = comptime if (is_256bits) "[48;5;{}m" else "[{}m";
            const value = comptime if (is_256bits) field_value & 0xFF else field_value + 10;
            const code = comptime blk: {
                var buf: [max_ansi_color_code_len]u8 = undefined;
                break :blk std.fmt.bufPrint(
                    &buf,
                    fmt,
                    .{value},
                ) catch panic(
                    "Internal error: buffer size for ANSI color codes it too small when formattting background code {any}",
                    .{self},
                );
            };
            if (field_value == @intFromEnum(self)) {
                return esc ++ code;
            }
        }
        unreachable;
    }
};

test "ansi color codes" {
    try std.testing.expectEqualStrings(
        esc ++ "[30m",
        AnsiColorCodes.black.asText(),
    );
    try std.testing.expectEqualStrings(
        esc ++ "[37m",
        AnsiColorCodes.white.asText(),
    );

    try std.testing.expectEqualStrings(
        blue_bg,
        AnsiColorCodes.blue.asBackground(),
    );

    try std.testing.expectEqualSlices(
        u8,
        clay_bg,
        AnsiColorCodes.clay.asBackground(),
    );

    try std.testing.expectEqualStrings(
        esc ++ "[40m",
        AnsiColorCodes.black.asBackground(),
    );
    try std.testing.expectEqualStrings(
        esc ++ "[47m",
        AnsiColorCodes.white.asBackground(),
    );
}

const StyleOptions = struct {
    text_color: ?AnsiColorCodes = null,
    bg_color: ?AnsiColorCodes = null,
    bold: bool = false,
    italic: bool = false,
    dim: bool = false,
    framed: bool = false,
    line_breaks: usize = 1,
    frame_params: ?FrameParameters = null,

    pub fn getTextColor(self: StyleOptions) []const u8 {
        const color = self.text_color orelse AnsiColorCodes.default;
        return color.asText();
    }

    pub fn getBackgroundColor(self: StyleOptions) []const u8 {
        const color = self.bg_color orelse AnsiColorCodes.default;
        return color.asBackground();
    }
};

const FrameParameters = struct {
    char: u8 = '*',
    horizontal_pad: usize = 2,
    vertical_pad: usize = 1,
};

pub const Style = enum {
    Header1,
    Header2,
    Entry,
    Field,
    Hint,
    Error,
    Border,

    pub fn lookupStyle(self: Style, palette: std.StaticStringMap(StyleOptions)) ?StyleOptions {
        const _info = @typeInfo(Style).@"enum";
        inline for (0.., _info.field_names) |i, name| {
            if (_info.field_values[i] == @intFromEnum(self)) {
                return palette.get(name);
            }
        }
        unreachable;
    }
};

pub const RichWriter = struct {
    writer: *std.Io.Writer,
    on_error: ?(*const fn (anyerror) void) = null,
    palette: std.StaticStringMap(StyleOptions) = default_palette,

    fn handleError(self: RichWriter, err: anyerror) void {
        if (self.on_error) |handler| {
            handler(err);
        } else panic("Writer {} failed: {}, no error handler defined\n", .{ self, err });
    }

    pub fn write(self: RichWriter, bytes: []const u8) void {
        _ = self.writer.write(bytes) catch |err| {
            if (self.on_error) |handler| {
                handler(err);
            } else panic("Writer {} failed to write {s}, no error handler defined\n", .{ self, bytes });
        };
    }

    pub fn print(self: RichWriter, comptime format: []const u8, args: anytype) void {
        _ = self.writer.print(format, args) catch |err| {
            if (self.on_error) |handler| {
                handler(err);
            } else panic("Writer {} failed to print {s} with arguments {any}, no error handler defined\n", .{
                self,
                format,
                args,
            });
        };
    }

    pub fn styledPrint(
        self: RichWriter,
        comptime format: []const u8,
        options: StyleOptions,
        args: anytype,
    ) void {
        writeStylePrefix(self.writer, options) catch |err| self.handleError(err);
        if (options.framed) {
            printFramedText(self.writer, options.frame_params orelse .{}, format, args) catch unreachable;
        } else {
            self.print(format, args);
        }
        self.write(reset);
        for (0..options.line_breaks) |_| {
            self.write("\n");
        }
    }

    /// Draws a table, styled with the palette's `Border` and `Header2` styles
    /// unless `options` overrides them.
    pub fn table(
        self: RichWriter,
        headers: ?[]const []const u8,
        rows: []const []const []const u8,
        options: TableOptions,
    ) void {
        var opts = options;
        if (opts.border_style == null) opts.border_style = Style.Border.lookupStyle(self.palette);
        if (opts.header_style == null) opts.header_style = Style.Header2.lookupStyle(self.palette);
        writeTable(self.writer, headers, rows, opts) catch |err| self.handleError(err);
    }

    pub fn richPrint(self: RichWriter, comptime format: []const u8, style: Style, args: anytype) void {
        if (style.lookupStyle(self.palette)) |options| {
            self.styledPrint(format, options, args);
        } else {
            panic("Style variant not declared in Palette: {any}", .{style});
        }
    }
};

fn writeStylePrefix(writer: *std.Io.Writer, options: StyleOptions) !void {
    if (options.bold) try writer.writeAll(bold);
    if (options.italic) try writer.writeAll(italic);
    if (options.dim) try writer.writeAll(dim);
    try writer.writeAll(options.getBackgroundColor());
    try writer.writeAll(options.getTextColor());
}

const CellContent = union(enum) { frame, pad, text: usize };

const max_terminal_size = 100 * 100;

pub fn printFramedText(writer: *std.Io.Writer, parameters: FrameParameters, comptime format: []const u8, args: anytype) !void {
    var buf: [max_terminal_size]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, format, args) catch {
        panic("Configured max terminal size is unsufficient", .{});
    };
    try writeFramedText(writer, text, parameters);
}

pub fn writeFramedText(writer: *std.Io.Writer, text: []const u8, parameters: FrameParameters) !void {
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
        if (j != height - 1) {
            try writer.writeByte('\n');
        }
    }
    try writer.writeByte('\n');
}

pub const Align = enum { left, right, center };

pub const BorderStyle = enum { light, rounded, heavy, double, ascii };

const BorderSet = struct {
    h: []const u8,
    v: []const u8,
    tl: []const u8,
    tr: []const u8,
    bl: []const u8,
    br: []const u8,
    t_down: []const u8,
    t_up: []const u8,
    t_right: []const u8,
    t_left: []const u8,
    cross: []const u8,
};

fn borderSet(style: BorderStyle) BorderSet {
    return switch (style) {
        .light => .{ .h = "─", .v = "│", .tl = "┌", .tr = "┐", .bl = "└", .br = "┘", .t_down = "┬", .t_up = "┴", .t_right = "├", .t_left = "┤", .cross = "┼" },
        .rounded => .{ .h = "─", .v = "│", .tl = "╭", .tr = "╮", .bl = "╰", .br = "╯", .t_down = "┬", .t_up = "┴", .t_right = "├", .t_left = "┤", .cross = "┼" },
        .heavy => .{ .h = "━", .v = "┃", .tl = "┏", .tr = "┓", .bl = "┗", .br = "┛", .t_down = "┳", .t_up = "┻", .t_right = "┣", .t_left = "┫", .cross = "╋" },
        .double => .{ .h = "═", .v = "║", .tl = "╔", .tr = "╗", .bl = "╚", .br = "╝", .t_down = "╦", .t_up = "╩", .t_right = "╠", .t_left = "╣", .cross = "╬" },
        .ascii => .{ .h = "-", .v = "|", .tl = "+", .tr = "+", .bl = "+", .br = "+", .t_down = "+", .t_up = "+", .t_right = "+", .t_left = "+", .cross = "+" },
    };
}

pub const TableOptions = struct {
    border: BorderStyle = .rounded,
    /// Spaces on each side of a cell's content
    padding: usize = 1,
    /// Draw a rule between every row, not only below the header
    row_separators: bool = false,
    /// Per column; missing entries default to `.left`
    alignments: []const Align = &.{},
    /// Total table width, borders included. Wider columns are truncated with '…'
    max_width: ?usize = null,
    border_style: ?StyleOptions = null,
    header_style: ?StyleOptions = null,
};

const max_table_columns = 32;

/// Number of terminal columns taken by `text`: ANSI escape sequences are
/// skipped and each UTF-8 codepoint counts for one column.
pub fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == 0x1b) {
            i = skipEscape(text, i);
        } else if (text[i] & 0xC0 != 0x80) {
            width += 1;
        }
    }
    return width;
}

/// Given `text[start] == ESC`, returns the index of the last byte of the sequence
fn skipEscape(text: []const u8, start: usize) usize {
    var i = start + 1;
    if (i < text.len and text[i] == '[') {
        i += 1;
        // CSI: parameter/intermediate bytes, then a final byte in 0x40..0x7E
        while (i < text.len and (text[i] < 0x40 or text[i] > 0x7E)) i += 1;
    }
    return @min(i, text.len -| 1);
}

/// Writes `text` cut to at most `max` columns (last one being '…' if cut).
/// Returns the number of columns written.
fn writeFitted(writer: *std.Io.Writer, text: []const u8, max: usize) !usize {
    const full = displayWidth(text);
    if (full <= max) {
        try writer.writeAll(text);
        return full;
    }
    if (max == 0) return 0;
    var visible: usize = 0;
    var saw_escape = false;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            const end = skipEscape(text, i) + 1;
            try writer.writeAll(text[i..end]);
            saw_escape = true;
            i = end;
            continue;
        }
        if (visible == max - 1) break;
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + len, text.len);
        try writer.writeAll(text[i..end]);
        visible += 1;
        i = end;
    }
    try writer.writeAll("…");
    if (saw_escape) try writer.writeAll(reset);
    return visible + 1;
}

fn writeRepeated(writer: *std.Io.Writer, s: []const u8, n: usize) !void {
    for (0..n) |_| try writer.writeAll(s);
}

fn writeBorder(writer: *std.Io.Writer, glyph: []const u8, style: ?StyleOptions) !void {
    if (style) |st| {
        try writeStylePrefix(writer, st);
        try writer.writeAll(glyph);
        try writer.writeAll(reset);
    } else try writer.writeAll(glyph);
}

fn writeRule(
    writer: *std.Io.Writer,
    set: BorderSet,
    left: []const u8,
    mid: []const u8,
    right: []const u8,
    widths: []const usize,
    opts: TableOptions,
) !void {
    if (opts.border_style) |st| try writeStylePrefix(writer, st);
    try writer.writeAll(left);
    for (widths, 0..) |w, i| {
        if (i > 0) try writer.writeAll(mid);
        try writeRepeated(writer, set.h, w + 2 * opts.padding);
    }
    try writer.writeAll(right);
    if (opts.border_style != null) try writer.writeAll(reset);
    try writer.writeByte('\n');
}

fn writeRow(
    writer: *std.Io.Writer,
    set: BorderSet,
    cells: []const []const u8,
    widths: []const usize,
    opts: TableOptions,
    cell_style: ?StyleOptions,
) !void {
    for (widths, 0..) |w, i| {
        try writeBorder(writer, set.v, opts.border_style);
        if (cell_style) |st| try writeStylePrefix(writer, st);
        try writeRepeated(writer, " ", opts.padding);

        // Alignment depends on the width of the text once truncated
        const text: []const u8 = if (i < cells.len) cells[i] else "";
        const shown = @min(displayWidth(text), w);
        const extra = w - shown;
        const alignment: Align = if (i < opts.alignments.len) opts.alignments[i] else .left;
        const before: usize = switch (alignment) {
            .left => 0,
            .right => extra,
            .center => extra / 2,
        };
        try writeRepeated(writer, " ", before);
        _ = try writeFitted(writer, text, w);
        try writeRepeated(writer, " ", extra - before);

        try writeRepeated(writer, " ", opts.padding);
        if (cell_style != null) try writer.writeAll(reset);
    }
    try writeBorder(writer, set.v, opts.border_style);
    try writer.writeByte('\n');
}

/// Shrinks the widest columns one column at a time until the table fits `max_width`
fn shrinkColumns(widths: []usize, max_width: usize, padding: usize) void {
    const overhead = widths.len * 2 * padding + widths.len + 1;
    var total = overhead;
    for (widths) |w| total += w;
    while (total > max_width) {
        var widest: usize = 0;
        for (widths, 0..) |w, i| {
            if (w > widths[widest]) widest = i;
        }
        if (widths[widest] <= 1) return;
        widths[widest] -= 1;
        total -= 1;
    }
}

/// Draws a table with continuous box-drawing borders. Rows may have fewer
/// cells than there are columns; missing cells are left blank.
pub fn writeTable(
    writer: *std.Io.Writer,
    headers: ?[]const []const u8,
    rows: []const []const []const u8,
    opts: TableOptions,
) !void {
    var ncols: usize = if (headers) |h| h.len else 0;
    for (rows) |row| ncols = @max(ncols, row.len);
    if (ncols == 0) return;
    if (ncols > max_table_columns) return error.TooManyColumns;

    var width_buf: [max_table_columns]usize = @splat(0);
    const widths = width_buf[0..ncols];
    if (headers) |h| {
        for (h, 0..) |cell, i| widths[i] = @max(widths[i], displayWidth(cell));
    }
    for (rows) |row| {
        for (row, 0..) |cell, i| widths[i] = @max(widths[i], displayWidth(cell));
    }
    if (opts.max_width) |max_width| shrinkColumns(widths, max_width, opts.padding);

    const set = borderSet(opts.border);
    try writeRule(writer, set, set.tl, set.t_down, set.tr, widths, opts);
    if (headers) |h| {
        try writeRow(writer, set, h, widths, opts, opts.header_style);
        try writeRule(writer, set, set.t_right, set.cross, set.t_left, widths, opts);
    }
    for (rows, 0..) |row, j| {
        try writeRow(writer, set, row, widths, opts, null);
        if (opts.row_separators and j + 1 < rows.len) {
            try writeRule(writer, set, set.t_right, set.cross, set.t_left, widths, opts);
        }
    }
    try writeRule(writer, set, set.bl, set.t_up, set.br, widths, opts);
}

test "table: rounded borders with header and alignment" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeTable(&w, &.{ "Name", "Qty" }, &.{
        &.{ "apple", "3" },
        &.{ "kiwi", "12" },
    }, .{ .alignments = &.{ .left, .right } });
    try std.testing.expectEqualStrings(
        \\╭───────┬─────╮
        \\│ Name  │ Qty │
        \\├───────┼─────┤
        \\│ apple │   3 │
        \\│ kiwi  │  12 │
        \\╰───────┴─────╯
        \\
    , w.buffered());
}

test "table: ascii, no header, row separators, ragged row" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeTable(&w, null, &.{
        &.{ "a", "b" },
        &.{"c"},
    }, .{ .border = .ascii, .row_separators = true });
    try std.testing.expectEqualStrings(
        \\+---+---+
        \\| a | b |
        \\+---+---+
        \\| c |   |
        \\+---+---+
        \\
    , w.buffered());
}

test "table: utf-8 and ansi cells keep alignment" {
    try std.testing.expectEqual(@as(usize, 4), displayWidth("café"));
    try std.testing.expectEqual(@as(usize, 3), displayWidth(esc ++ "[1;31m" ++ "abc" ++ reset));

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeTable(&w, null, &.{
        &.{"café"},
        &.{esc ++ "[1mab" ++ reset},
    }, .{ .border = .light });
    try std.testing.expectEqualStrings(
        "┌──────┐\n" ++
            "│ café │\n" ++
            "│ " ++ esc ++ "[1mab" ++ reset ++ "   │\n" ++
            "└──────┘\n",
        w.buffered(),
    );
}

test "table: max_width truncates widest column" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeTable(&w, &.{ "id", "description" }, &.{
        &.{ "1", "a very long description" },
    }, .{ .max_width = 16 });
    try std.testing.expectEqualStrings(
        \\╭────┬─────────╮
        \\│ id │ descri… │
        \\├────┼─────────┤
        \\│ 1  │ a very… │
        \\╰────┴─────────╯
        \\
    , w.buffered());
}

test "table: empty table writes nothing" {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeTable(&w, null, &.{}, .{});
    try std.testing.expectEqual(@as(usize, 0), w.buffered().len);
}

// Base color palettes
pub const clay_palette = std.StaticStringMap(StyleOptions).initComptime(.{
    .{ "Header1", StyleOptions{ .text_color = .clay, .framed = true, .bold = true } },
    .{ "Header2", StyleOptions{ .text_color = .black, .bg_color = .yellow } },
    .{ "Entry", StyleOptions{ .italic = true } },
    .{ "Field", StyleOptions{ .italic = true, .line_breaks = 0 } },
    .{ "Hint", StyleOptions{ .bold = true, .text_color = .clay, .line_breaks = 0 } },
    .{ "Error", StyleOptions{ .text_color = .red, .bold = true } },
    .{ "Border", StyleOptions{ .text_color = .clay } },
});
pub const blueish_palette = std.StaticStringMap(StyleOptions).initComptime(.{
    .{ "Header1", StyleOptions{ .text_color = .cyan, .bg_color = .default, .framed = true } },
    .{
        "Header2",
        StyleOptions{ .text_color = .cyan, .bg_color = .black },
    },
    .{ "Entry", StyleOptions{ .italic = true } },
    .{ "Field", StyleOptions{ .italic = true, .line_breaks = 0, .bg_color = .black } },
    .{ "Hint", StyleOptions{ .italic = true, .text_color = .cyan, .line_breaks = 0 } },
    .{ "Error", StyleOptions{ .text_color = .red, .bold = true } },
    .{ "Border", StyleOptions{ .text_color = .cyan } },
});

pub const christmas_palette = std.StaticStringMap(StyleOptions).initComptime(.{
    .{ "Header1", StyleOptions{ .text_color = .black, .bg_color = .green, .framed = true } },
    .{
        "Header2",
        StyleOptions{ .text_color = .green, .bg_color = .default },
    },
    .{ "Entry", StyleOptions{ .text_color = .red, .italic = true } },
    .{ "Field", StyleOptions{ .text_color = .red, .italic = true, .line_breaks = 0, .bg_color = .black } },
    .{ "Hint", StyleOptions{ .italic = true, .text_color = .green, .line_breaks = 0 } },
    .{ "Error", StyleOptions{ .text_color = .red, .bold = true } },
    .{ "Border", StyleOptions{ .text_color = .green } },
});

pub const forest_palette = std.StaticStringMap(StyleOptions).initComptime(.{
    .{ "Header1", StyleOptions{ .text_color = .green, .bg_color = .default, .framed = true } },
    .{ "Header2", StyleOptions{ .text_color = .black, .bg_color = .green } },
    .{ "Entry", StyleOptions{ .text_color = .green, .bg_color = .black, .italic = true } },
    .{ "Field", StyleOptions{ .text_color = .green, .italic = true, .line_breaks = 0, .bg_color = .black } },
    .{ "Hint", StyleOptions{ .italic = true, .text_color = .green, .line_breaks = 0 } },
    .{ "Error", StyleOptions{ .text_color = .red, .bold = true } },
    .{ "Border", StyleOptions{ .text_color = .green, .dim = true } },
});

pub const palettes = std.StaticStringMap(std.StaticStringMap(StyleOptions)).initComptime(.{
    .{ "clay", clay_palette },
    .{ "blue", blueish_palette },
    .{ "christmas", christmas_palette },
    .{ "forest", forest_palette },
    .{ "default", default_palette },
});
const default_palette = blueish_palette;
