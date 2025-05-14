//! Tests all examples
const std = @import("std");
const easycli = @import("parser");
const OptionInfo = easycli.OptionInfo;
const ArgInfo = easycli.ArgInfo;

// importing examples
const whoami = @import("whoami.zig");
// TODO: other ones

/// Imports the CliParser object under test for the given example
pub fn getCliParser(comptime example: Example) type {
    return switch (example) {
        .whoami => whoami.ParserT,
    };
}

/// All the examples under test
const Example = enum {
    whoami,

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
    subcmd: Subcommands,
};

fn takeExampleSnapshot(comptime example: Example, output_name: []const u8) !void {
    const out = try std.fs.cwd().createFile(output_name, .{});
    const writer = out.writer();
    const ParserT = comptime getCliParser(example);
    const prompt = @tagName(example) ++ " --help";
    var arg_it = std.mem.splitSequence(u8, prompt, " ");
    _ = try ParserT.runStandaloneWithOptions(&arg_it, writer);
}

pub fn takeSnapshot(options: SnapshotOptions) void {
    inline for (std.meta.fields(Example)) |field| {
        const target: Example = @enumFromInt(field.value);
        var is_target: bool = true;
        if (options.example) |example| {
            is_target = (example == target);
        }
        if (is_target) {
            std.debug.print("Taking snapshot of {s}!\n", .{@tagName(target)});
            var buf: [50]u8 = undefined;
            const output_name = std.fmt.bufPrint(&buf, "{s}_snapshot.txt", .{@tagName(target)}) catch unreachable;
            takeExampleSnapshot(target, output_name) catch unreachable;
            std.debug.print("Snapshot written at {s}\n", .{output_name});
        }
    }
    return;
}

pub fn main() !void {
    const ParserT = easycli.CliParser(.{
        .args = MainArg,
    });
    const main_params = if (try ParserT.runStandalone()) |p| p else return;
    switch (main_params.args.subcmd) {
        .take_snapshot => |p| takeSnapshot(p.options),
    }
}
