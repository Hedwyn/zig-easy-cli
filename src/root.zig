/// Engine for the CLI utility
const std = @import("std");
const testing = std.testing;

// types
const Allocator = std.mem.Allocator;
// const ArgIterator = std.process.ArgIterator;
const ArgIterator = anyopaque;

pub const CliContext = struct {
    name: ?[]const u8 = null,
};

pub const CliError = error{
    MissingArgument,
    InvalidOption,
    InvalidCharacter,
    MemoryError,
    EmptyArguments,
    MaxTwoDashesAllowed,
    NotSupported,
    InvalidContainer,
    UnknownArgument,
};

// ShortFlag are passed with `-', LongFlag with '--',
const FlagType = enum {
    Argument,
    ShortFlag,
    LongFlag,
};

pub fn CliParser(comptime T: type) type {
    return struct {
        context: CliContext,
        allocator: Allocator,

        const Self = @This();

        pub fn parseArg(self: Self, arg_name: []const u8, arg_value: []const u8, flag_type: FlagType, container: *T) CliError!void {
            const container_info = @typeInfo(T);
            _ = self;
            _ = flag_type;
            const struct_info = switch (container_info) {
                .Struct => |s| s,
                else => return .InvalidContainer,
            };
            inline for (struct_info.fields) |field| {
                if (std.mem.eql(u8, field.name, arg_name)) {
                    @field(container, field.name) = arg_value;
                    return;
                }
            }
            return CliError.UnknownArgument;
        }

        pub fn introspectArgName(_: Self, arg_idx: usize) CliError![]const u8 {
            _ = arg_idx;
            return CliError.NotSupported;
        }

        pub fn parse(self: Self, arg_it: anytype) CliError!*T {
            const params: *T = self.allocator.create(T) catch return CliError.MemoryError;
            var ctx = self.context;
            var flag_type: ?FlagType = null;
            var current_arg_name: []const u8 = "";
            // If no explicit client name was passed,using process name
            const process_name: []const u8 = arg_it.next() orelse return CliError.EmptyArguments;
            ctx.name = ctx.name orelse process_name;

            while (arg_it.next()) |arg| {
                var arg_idx: usize = 0;

                if (flag_type) |flag| {
                    try self.parseArg(current_arg_name, arg, flag, params);
                    // consuming flag type
                    flag_type = null;
                    continue;
                }
                flag_type = .Argument;
                var arg_name_start_idx: usize = 0;
                for (arg) |char| {
                    if (char != '-') {
                        break;
                    }
                    flag_type = switch (flag_type.?) {
                        .Argument => .ShortFlag,
                        .ShortFlag => .LongFlag,
                        .LongFlag => return CliError.MaxTwoDashesAllowed,
                    };
                    arg_name_start_idx += 1;
                }
                current_arg_name = switch (flag_type.?) {
                    .Argument => blk: {
                        arg_idx += 1;
                        break :blk try self.introspectArgName(arg_idx);
                    },
                    else => arg[arg_name_start_idx..],
                };
            }
            return params;
        }
    };
}

// Basic test case that only uses options and does not require casting
test "parse with string parameters only" {
    const prompt = "testcli --arg_1 Argument1";
    var arguments = std.mem.split(u8, prompt, " ");
    const allocator = std.heap.page_allocator;
    const ctx = CliContext{};
    const Params = struct {
        arg_1: ?[]const u8,
    };
    const parser = CliParser(Params){ .context = ctx, .allocator = allocator };
    const params = try parser.parse(&arguments);
    try std.testing.expectEqualStrings("Argument1", params.arg_1.?);
}
