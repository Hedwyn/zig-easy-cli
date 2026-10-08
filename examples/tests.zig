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

// Compile time static limit on expected cmd size output
const cmd_output_max_size = 1000;

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
            const values = std.enums.values(Example);
            var variants: [values.len]Example = undefined;
            for (0.., values) |i, value| variants[i] = value;
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

const take_snapshot_doc = [_]OptionInfo{
    .{ .name = "example", .help = "Name of the example to take a snapshot from" },
};

const test_snapshot_doc = [_]OptionInfo{
    .{ .name = "example", .help = "Name of the example from which snapshots should be tested" },
};

const Subcommands = union(enum) {
    take_snapshot: easycli.CliParser(
        .{
            .opts = SnapshotOptions,
            .opts_info = &take_snapshot_doc,
        },
    ),
    test_snapshots: easycli.CliParser(
        .{
            .opts = SnapshotOptions,
            .opts_info = &test_snapshot_doc,
        },
    ),
};

const MainArg = struct {
    subcmd: ?Subcommands = null,
};

fn takeExampleSnapshot(io: std.Io, comptime example: Example, output_name: []const u8, prompt: []const u8) !void {
    const out = try std.Io.Dir.cwd().createFile(io, output_name, .{});
    defer out.close(io);
    var file_buf: [cmd_output_max_size]u8 = undefined;
    var file_writer = out.writer(io, &file_buf);
    const ParserT = comptime getCliParser(example);
    var arg_it = std.mem.splitSequence(u8, prompt, " ");
    _ = try ParserT.runStandaloneWithOptions(io, &arg_it, &file_writer.interface);
    try file_writer.interface.flush();
}

fn testExampleSnapshot(io: std.Io, comptime example: Example, prompt: []const u8, expected: []const u8) !void {
    var buf: [cmd_output_max_size]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const ParserT = comptime getCliParser(example);
    var arg_it = std.mem.splitSequence(u8, prompt, " ");
    _ = try ParserT.runStandaloneWithOptions(io, &arg_it, &writer);
    // TODO: compare `writer.buffered()` with `expected` once snapshots are stable
    _ = expected;
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

pub fn takeSnapshot(io: std.Io, options: SnapshotOptions) void {
    inline for (std.enums.values(Example)) |target| {
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
                takeExampleSnapshot(io, target, output_name, prompt) catch unreachable;
                std.debug.print("Snapshot written at {s}\n", .{output_name});
            }
        }
    }
    return;
}

pub fn testSnapshot(io: std.Io, options: SnapshotOptions) void {
    inline for (std.enums.values(Example)) |target| {
        var is_target: bool = true;
        if (options.example) |example| {
            is_target = (example == target);
        }
        if (is_target) {
            std.debug.print("Testing snapshot of {s}\n", .{@tagName(target)});
            inline for (comptime generatePrompts(target)) |prompt| {
                var fname_buf: [100]u8 = undefined;
                var fcontent_buf: [cmd_output_max_size]u8 = undefined;
                const fname = convertPromptToFilename(prompt);
                std.log.debug("Using filename {s}", .{fname});
                const snapshot_path = std.fmt.bufPrint(&fname_buf, "examples/snapshots/{s}/{s}.txt", .{
                    @tagName(target),
                    fname,
                }) catch unreachable;
                const expected = std.Io.Dir.cwd().readFile(io, snapshot_path, &fcontent_buf) catch unreachable;
                testExampleSnapshot(io, target, snapshot_path, expected) catch unreachable;
            }
        }
    }
    return;
}

pub fn main(init: std.process.Init) !void {
    const ParserT = easycli.CliParser(.{
        .args = MainArg,
    });
    const main_params = if (try ParserT.runStandalone(init)) |p| p else return;
    const cmd = main_params.args.subcmd orelse {
        std.debug.print("You must provide a subcommand !", .{});
        return;
    };
    switch (cmd) {
        .take_snapshot => |p| takeSnapshot(init.io, p.options),
        .test_snapshots => |p| testSnapshot(init.io, p.options),

    }
}
