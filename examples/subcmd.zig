/// Small demo code
const std = @import("std");
const easycli = @import("parser");
const OptionInfo = easycli.OptionInfo;
const ArgInfo = easycli.ArgInfo;

const WhoamiOptions = struct {
    surname: ?[]const u8 = null,
    grade: enum { Employee, Boss } = .Employee,
    secret: ?[]const u8 = null,
};
const WhoamiArg = struct { name: ?[]const u8 };

const Subcommands = union(enum) {
    whoami: easycli.CliParser(
        .{
            .opts = WhoamiOptions,
            .args = WhoamiArg,
            .opts_info = &options_doc,
            .args_info = &arg_doc,
        },
    ),
};

const MainArg = struct {
    subcmd: Subcommands,
};

const options_doc = [_]OptionInfo{
    .{ .name = "surname", .help = "Your surname" },
    .{ .name = "secret", .help = "Your secret", .hidden = true },
};

const arg_doc = [_]ArgInfo{
    .{ .name = "name", .help = "Your name" },
};

pub const std_options = std.Options{
    // Set the log level to info
    .log_level = .info,

    // Define logFn to override the std implementation
    .logFn = easycli.logHandler,
};

pub fn handleWhoami(params: anytype) void {
    const name = if (params.args.name) |n| n else {
        std.debug.print("You need to pass your name !\n", .{});
        return;
    };
    if (params.options.surname) |surname| {
        std.debug.print("Hello {s} {s}!\n", .{ name, surname });
    } else {
        std.debug.print("Hello {s}!\n", .{name});
    }

    if (params.options.secret) |secret| {
        std.debug.print("You discovered the secret flag ! Your secret is {s}.\n", .{secret});
    }
}

pub const ParserT = easycli.CliParser(.{
    .args = MainArg,
});

pub fn main() !void {
    const main_params = if (try ParserT.runStandalone()) |p| p else return;

    const params = switch (main_params.args.subcmd) {
        .whoami => |p| p,
    };
    handleWhoami(params);
}
