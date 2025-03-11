/// Small demo code
const std = @import("std");
const easycli = @import("parser");
const OptionInfo = easycli.OptionInfo;
const ArgInfo = easycli.ArgInfo;

const DemoOptions = struct {
    surname: ?[]const u8 = null,
    grade: enum { Employee, Boss } = .Employee,
    secret: ?[]const u8 = null,
};
const DemoArgs = struct { name: ?[]const u8 };

const options_doc = [_]OptionInfo{
    .{ .name = "surname", .help = "Your surname" },
};

const arg_doc = [_]ArgInfo{
    .{ .name = "name", .help = "Your name" },
};

pub fn main() !void {
    const ParserT = easycli.CliParser(.{
        .opts = DemoOptions,
        .args = DemoArgs,
        .opts_info = &options_doc,
        .args_info = &arg_doc,
        .welcome_msg =
        \\Pass your identity, the program will echo it for you.
        ,
    });
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
    std.debug.print("Your grade is {s}.\n", .{@tagName(params.options.grade)});
}
