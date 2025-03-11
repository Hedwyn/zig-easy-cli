/// A demonstration of hidden options
const std = @import("std");
const easycli = @import("parser");
const OptionInfo = easycli.OptionInfo;
const ArgInfo = easycli.ArgInfo;

const DemoOptions = struct {
    password: ?[]const u8 = null,
};
const DemoArgs = struct { username: ?[]const u8 };

const options_doc = [_]OptionInfo{
    .{ .name = "secret", .help = "Your secret", .hidden = true },
};

const arg_doc = [_]ArgInfo{
    .{ .name = "name", .help = "A mysterious username" },
};

pub fn main() !void {
    const ParserT = easycli.CliParser(.{
        .opts = DemoOptions,
        .args = DemoArgs,
        .opts_info = &options_doc,
        .args_info = &arg_doc,
        .welcome_msg =
        \\A mysterious program... what does it do ?
        ,
    });
    const params = if (try ParserT.runStandalone()) |p| p else return;

    const username = params.args.username orelse {
        std.debug.print("Please pass a username\n", .{});
        return;
    };
    if (params.options.password) |pwd| {
        if (std.mem.eql(u8, pwd, "123456")) {
            std.debug.print("Congrats ! You authenticated successfully\n", .{});
            return;
        }
        std.debug.print("Congrats, you discovered the secret option. However, password {s} is not correct. Hint: try 123456\n", .{pwd});
    } else {
        std.debug.print("Hi {s}...nothing to see here. Hint: try passing --password\n", .{username});
    }
}
