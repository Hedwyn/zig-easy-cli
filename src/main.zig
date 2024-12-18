/// Small demo code
const std = @import("std");
const easycli = @import("parser.zig");

const DemoOptions = struct { surname: ?[]const u8, grade: enum { Employee, Boss } };
const DemoArgs = struct { name: ?[]const u8 };

pub fn main() !void {
    const ParserT = easycli.CliParser(DemoOptions, DemoArgs);
    const params = if (try ParserT.run_standalone()) |p| p else return;
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
