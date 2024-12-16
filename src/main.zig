/// Small demo code
const std = @import("std");
const easycli = @import("parser.zig");

const DemoOptions = struct { surname: ?[]const u8 };
const DemoArgs = struct { name: ?[]const u8 };

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var args_it = std.process.args();

    const builtin_params = try easycli.preprocess(allocator, &args_it);
    if (builtin_params.options.help) {
        std.debug.print("Pass your name as argument and optionally your surname with --surname !\n", .{});
        return;
    }
    args_it = std.process.args();
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
