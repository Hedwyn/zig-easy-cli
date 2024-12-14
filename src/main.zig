/// Small demo code
const std = @import("std");
const easycli = @import("root.zig");

const DemoOptions = struct { surname: ?[]const u8 };
const DemoArgs = struct { name: ?[]const u8 };

pub fn main() !void {
    var args_it = std.process.args();
    const allocator = std.heap.page_allocator;
    const ctx = easycli.CliContext{};
    const parser = easycli.CliParser(DemoOptions, DemoArgs){ .context = ctx, .allocator = allocator };
    const params = try parser.parse(&args_it);

    const name = if (params.arguments.name) |n| n else {
        std.debug.print("You need to pass your name !\n", .{});
        return;
    };
    if (params.options.surname) |surname| {
        std.debug.print("Hello {s} {s}!\n", .{ name, surname });
    } else {
        std.debug.print("Hello {s}!\n", .{name});
    }
}
