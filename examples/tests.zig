//! Tests all examples
const std = @import("std");
const easycli = @import("parser");
const OptionInfo = easycli.OptionInfo;
const ArgInfo = easycli.ArgInfo;

// importing examples
const whoami = @import("whoami.zig");
const subcmd = @import("subcmd.zig");
const logs = @import("logs.zig");
const secret = @import("secret.zig");
const minimal = @import("minimal.zig");

/// Imports the CliParser object under test for the given example
pub fn getCliParser(comptime example: Example) type {
    return switch (example) {
        .whoami => whoami.ParserT,
        .subcmd => subcmd.ParserT,
        .logs => logs.ParserT,
        .secret => secret.ParserT,
        .minimal => minimal.ParserT,
    };
}

/// All the examples under test
const Example = enum {
    whoami,
    subcmd,
    logs,
    secret,
    minimal,

    pub fn all() []const Example {
        const examples = comptime blk: {
            const fields = std.meta.fields(Example);
            var variants: [fields.len]Example = undefined;
            for (0.., fields) |i, field| {
                variants[i] = @enumFromInt(field.value);
            }
            break :blk variants;
        };
        return &examples;
    }
};

pub fn generatePrompts(comptime example: Example) []const []const u8 {
    _ = example;
    return &.{
        "--help",
    };
}

/// Parameters for the snapshot command
const SnapshotOptions = struct {
    example: ?Example = null,
};

const snapshot_option_docs = [_]OptionInfo{
    .{ .name = "example", .help = "Name of the example to take a snapshot from" },
};

const Subcommands = union(enum) {
    take_snapshot: easycli.CliParser(
        .{
            .opts = SnapshotOptions,
            .opts_info = &snapshot_option_docs,
        },
    ),
};

const MainArg = struct {
    subcmd: ?Subcommands = null,
};

fn takeExampleSnapshot(comptime example: Example, output_name: []const u8, prompt: []const u8) !void {
    const out = try std.fs.cwd().createFile(output_name, .{});
    const writer = out.writer();
    const ParserT = comptime getCliParser(example);
    var arg_it = std.mem.splitSequence(u8, prompt, " ");
    _ = try ParserT.runStandaloneWithOptions(&arg_it, writer);
}

fn convertPromptToFilename(comptime prompt: []const u8) []const u8 {
    const literal = comptime blk: {
        var buf: [prompt.len]u8 = undefined;
        for (0.., prompt) |i, char| {
            const converted = switch (char) {
                '-' => '_',
                '_' => '-',
                else => char,
            };
            buf[i] = converted;
        }
        break :blk buf;
    };
    return &literal;
}

pub fn takeSnapshot(options: SnapshotOptions) void {
    inline for (std.meta.fields(Example)) |field| {
        const target: Example = @enumFromInt(field.value);
        var is_target: bool = true;
        if (options.example) |example| {
            is_target = (example == target);
        }
        if (is_target) {
            std.debug.print("Taking snapshot of {s}\n", .{@tagName(target)});
            inline for (comptime generatePrompts(target)) |prompt| {
                var buf: [100]u8 = undefined;
                const fname = convertPromptToFilename(prompt);
                std.log.debug("Using filename {s}", .{fname});
                const output_name = std.fmt.bufPrint(&buf, "examples/snapshots/{s}/{s}.txt", .{
                    @tagName(target),
                    fname,
                }) catch unreachable;
                takeExampleSnapshot(target, output_name, prompt) catch unreachable;
                std.debug.print("Snapshot written at {s}\n", .{output_name});
            }
        }
    }
    return;
}

pub fn main() !void {
    const ParserT = easycli.CliParser(.{
        .args = MainArg,
    });
    const main_params = if (try ParserT.runStandalone()) |p| p else return;
    const cmd = main_params.args.subcmd orelse {
        std.debug.print("You must provide a subcommand !", .{});
        return;
    };
    switch (cmd) {
        .take_snapshot => |p| takeSnapshot(p.options),
    }
}
