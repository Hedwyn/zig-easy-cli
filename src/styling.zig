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
    clay = 256 + 172,
    turquoise = 256 + 29,

    pub fn asText(self: AnsiColorCodes) []const u8 {
        inline for (std.meta.fields(AnsiColorCodes)) |field| {
            const is_256bits = field.value >= 0xFF;
            const fmt = comptime if (is_256bits) "[38;5;{}m" else "[{}m";
            const value = comptime if (is_256bits) field.value & 0xFF else field.value;

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
            if ((field.value) == @intFromEnum(self)) {
                return esc ++ code;
            }
        }
        unreachable;
    }

    pub fn asBackground(self: AnsiColorCodes) []const u8 {
        inline for (std.meta.fields(AnsiColorCodes)) |field| {
            const is_256bits = field.value >= 0xFF;
            const fmt = comptime if (is_256bits) "[48;5;{}m" else "[{}m";
            const value = comptime if (is_256bits) field.value & 0xFF else field.value + 10;
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
            if ((field.value) == @intFromEnum(self)) {
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

    pub fn lookupPalette(self: Style, palette: std.StaticStringMap(StyleOptions)) ?StyleOptions {
        inline for (std.meta.fields(Style)) |field| {
            if ((field.value) == @intFromEnum(self)) {
                return palette.get(field.name);
            }
        }
        unreachable;
    }
};

pub const RichWriter = struct {
    writer: *const Writer,
    on_error: ?(*const fn (WriteError) void) = null,

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
        if (options.bold) {
            self.write(bold);
        }
        if (options.italic) {
            self.write(italic);
        }
        if (options.dim) {
            self.write(dim);
        }
        self.write(options.getBackgroundColor());
        self.write(options.getTextColor());
        if (options.framed) {
            printFramedText(self.writer, options.frame_params orelse .{}, format, args) catch unreachable;
        } else {
            self.print(format, args);
        }
        self.write(reset);
        for (options.line_breaks) |_| {
            self.write("\n");
        }
    }

    pub fn richPrint(self: RichWriter, comptime format: []const u8, style: Style, args: anytype) void {
        if (style.lookupPalette(default_palette)) |options| {
            self.styledPrint(format, options, args);
        } else {
            panic("Not supported {any}", .{style});
        }
    }
};

const CellContent = union(enum) { frame, pad, text: usize };

const max_terminal_size = 100 * 100;

pub fn printFramedText(writer: *const Writer, parameters: FrameParameters, comptime format: []const u8, args: anytype) !void {
    var buf: [max_terminal_size]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, format, args) catch {
        panic("Configured max terminal size is unsufficient", .{});
    };
    try writeFramedText(writer, text, parameters);
}

pub fn writeFramedText(writer: *const Writer, text: []const u8, parameters: FrameParameters) !void {
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

// Base color palettes
const clay_palette = std.StaticStringMap(StyleOptions).initComptime(.{
    .{ "Header1", .{ .text_color = .clay, .framed = true, .bold = true } },
    .{ "Header2", .{ .text_color = .black, .bg_color = .yellow } },
    .{ "Entry", .{ .italic = true } },
    .{ "Field", .{ .italic = true, .line_breaks = 0 } },
    .{ "Hint", .{ .bold = true, .line_breaks = 0 } },
});
const blueish_palette = std.StaticStringMap(StyleOptions).initComptime(.{
    .{ "Header1", .{ .text_color = .cyan, .bg_color = .black, .framed = true } },
    .{
        "Header2",
        .{ .text_color = .cyan, .bg_color = .black },
    },
    .{ "Entry", .{ .italic = true } },
    .{ "Field", .{ .italic = true, .line_breaks = 0 } },
    .{ "Hint", .{ .italic = true, .text_color = .cyan, .line_breaks = 0 } },
});
const default_palette = blueish_palette;
