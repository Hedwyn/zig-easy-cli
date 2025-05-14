/// A minimal example,
/// to demonstrate a basic use case of the parser tha requires minimum input
/// from the developer
const std = @import("std");
const easycli = @import("parser");
const OptionInfo = easycli.OptionInfo;
const ArgInfo = easycli.ArgInfo;

const DemoOptions = struct {
    surname: ?[]const u8 = null,
};
const DemoArgs = struct { name: ?[]const u8 };

pub const ParserT = easycli.CliParser(.{
    .opts = DemoOptions,
    .args = DemoArgs,
});

pub fn main() !void {
    const params = if (try ParserT.runStandalone()) |p| p else return;

    const name = if (params.args.name) |n| n else {
        std.debug.print("You need to pass your name !\n", .{});
        return;
    };
    if (params.options.surname) |surname| {
        std.debug.print("Hello {s} {s}!\n", .{ name, surname });
    } else {
        std.debug.print("Hello {s}!\n", .{name});
    }
}
