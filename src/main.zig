/// Small demo code
const std = @import("std");
const easycli = @import("parser.zig");

const OptionInfo = easycli.OptionInfo;
const ArgInfo = easycli.ArgInfo;

const DemoOptions = struct {
    surname: ?[]const u8,
    grade: enum { Employee, Boss } = .Employee,
};
const DemoArgs = struct { name: ?[]const u8 };

const options_doc = [_]OptionInfo{
    .{ .name = "surname", .help = "Your surname" },
};

const arg_doc = [_]ArgInfo{
    .{ .name = "name", .help = "Your name" },
};
pub fn main() !void {
    const ParserT = easycli.CliParser(DemoOptions, DemoArgs);
    const params = if (try ParserT.runStandalone(.{
        .options_info = &options_doc,
        .arg_info = &arg_doc,
    })) |p| p else return;
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
