/// Small demo code
const std = @import("std");
const easycli = @import("parser.zig");

const DemoOptions = struct { surname: ?[]const u8, grade: enum { Employee, Boss } };
const DemoArgs = struct { name: ?[]const u8 };

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var args_it = std.process.args();
    const writer = std.io.getStdOut().writer();
    const ctx = easycli.CliContext{};
    const ParserT = easycli.CliParser(DemoOptions, DemoArgs);
    const parser = ParserT{ .context = ctx, .allocator = allocator };
    const params = try parser.parse(&args_it);

    if (params.builtin.help) {
        // _ = try writer.write("Pass your name as argument and optionally your surname with --surname !\n");
        try parser.emitHelp(writer);
        return;
    }

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
