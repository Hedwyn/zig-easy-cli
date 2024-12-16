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
    UnknownOption,
    UnknownArgument,
    TooManyArguments,
    TakesNoArgument,
    IncorrectArgumentType,
    InvalidChoice,
};

// ShortFlag are passed with `-', LongFlag with '--',
const FlagType = enum {
    Argument,
    ShortFlag,
    LongFlag,
};

pub const NoArguments = struct {};
pub const NoOptions = struct {};

/// Init all optional fields to null in a struct
fn initOptionals(comptime T: type, container: *T) void {
    inline for (std.meta.fields(T)) |field| {
        switch (@typeInfo(field.type)) {
            .Optional => @field(container, field.name) = null,
            else => continue,
        }
    }
}

fn autoCast(comptime T: type, value_str: []const u8) CliError!T {
    if (T == []const u8 or T == ?[]const u8) {
        return value_str;
    }
    return switch (@typeInfo(T)) {
        .Int => std.fmt.parseInt(T, value_str, 10) catch {
            return CliError.IncorrectArgumentType;
        },
        .Float => std.fmt.parseFloat(T, value_str) catch {
            return CliError.IncorrectArgumentType;
        },
        .Optional => |option| try autoCast(option.child, value_str),
        // note: for bool, having the flag in the first place means true
        .Bool => |_| true,
        .Enum => |choices| {
            inline for (choices.fields) |field| {
                if (std.mem.eql(u8, field.name, value_str)) {
                    return @enumFromInt(field.value);
                }
            }
            return CliError.InvalidChoice;
        },
        else => unreachable,
    };
}

pub fn CliParams(comptime OptionT: type, comptime ArgT: type) type {
    return struct {
        arguments: *ArgT,
        options: *OptionT,
    };
}

pub fn CliParser(comptime OptionT: type, comptime ArgT: type) type {
    return struct {
        context: CliContext,
        allocator: Allocator,

        const Params = CliParams(OptionT, ArgT);

        const Self = @This();

        fn isFlag(arg_name: []const u8) CliError!bool {
            inline for ([_]type{ OptionT, ArgT }) |container_type| {
                const type_st = switch (@typeInfo(container_type)) {
                    .Struct => |s| s,
                    else => unreachable,
                };
                inline for (type_st.fields) |field| {
                    if (std.mem.eql(u8, field.name, arg_name)) {
                        return switch (@typeInfo(field.type)) {
                            .Bool => true,
                            else => false,
                        };
                    }
                }
            }
            return CliError.UnknownArgument;
        }

        pub fn hasArguments() bool {
            return ArgT != NoArguments;
        }

        pub fn parseArg(self: Self, comptime T: type, arg_name: []const u8, arg_value: []const u8, flag_type: FlagType, container: *T) CliError!void {
            const container_info = @typeInfo(T);
            _ = self;
            _ = flag_type;
            const struct_info = switch (container_info) {
                .Struct => |s| s,
                else => return CliError.InvalidContainer,
            };
            inline for (struct_info.fields) |field| {
                if (std.mem.eql(u8, field.name, arg_name)) {
                    @field(container, field.name) = try autoCast(field.type, arg_value);
                    return;
                }
            }
            return CliError.UnknownOption;
        }

        pub fn introspectArgName(_: Self, arg_idx: usize) CliError![]const u8 {
            const container_info = @typeInfo(ArgT);
            const struct_info = switch (container_info) {
                .Struct => |s| s,
                else => return .InvalidContainer,
            };
            inline for (0.., struct_info.fields) |i, field| {
                if (i == arg_idx) {
                    return field.name;
                }
            }
            return CliError.TooManyArguments;
        }

        pub fn parse_with_options(self: Self, arg_it: anytype, ignore_unknown: bool) CliError!Params {
            const options: *OptionT = self.allocator.create(OptionT) catch return CliError.MemoryError;
            const arguments: *ArgT = self.allocator.create(ArgT) catch return CliError.MemoryError;
            initOptionals(OptionT, options);
            initOptionals(ArgT, arguments);
            const params = Params{ .options = options, .arguments = arguments };

            var is_option: bool = false;
            var ctx = self.context;
            var flag_type: ?FlagType = null;
            var current_arg_name: []const u8 = "";
            var arg_idx: usize = 0;

            // If no explicit client name was passed,using process name
            const process_name: []const u8 = arg_it.next() orelse return CliError.EmptyArguments;
            ctx.name = ctx.name orelse process_name;
            var next_arg = arg_it.next();
            var consume = true;

            while (next_arg) |arg| {
                // consume will be set to false if we have an argument
                defer next_arg = if (consume) arg_it.next() else next_arg;

                if (flag_type) |flag| {
                    consume = true;
                    defer flag_type = null;
                    _ = blk: {
                        if (is_option) {
                            break :blk self.parseArg(OptionT, current_arg_name, arg, flag, options);
                        }
                        break :blk self.parseArg(ArgT, current_arg_name, arg, flag, arguments);
                    } catch |e| {
                        if (!ignore_unknown) return e;
                        // else ignoring
                    };
                    // consuming flag type
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
                switch (flag_type.?) {
                    .Argument => {
                        if (!hasArguments()) continue;
                        is_option = false;
                        current_arg_name = try self.introspectArgName(arg_idx);
                        arg_idx += 1;
                        consume = false;
                    },
                    else => {
                        is_option = true;
                        current_arg_name = arg[arg_name_start_idx..];
                        if (try isFlag(current_arg_name)) {
                            try self.parseArg(OptionT, current_arg_name, arg, flag_type.?, options);
                        }
                    },
                }
            }
            return params;
        }

        pub fn parse(self: Self, arg_it: anytype) CliError!Params {
            return self.parse_with_options(arg_it, true);
        }
    };
}

pub const BuiltinOptions = struct {
    help: bool,
};
pub const BuiltinParser = CliParser(BuiltinOptions, NoArguments);

pub fn preprocess(allocator: Allocator, arg_it: anytype) CliError!BuiltinParser.Params {
    // Running built-in arguments first
    const builtin_parser = BuiltinParser{ .context = .{}, .allocator = allocator };
    return try builtin_parser.parse_with_options(arg_it, true);
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
    const parser = CliParser(Params, struct {}){ .context = ctx, .allocator = allocator };
    const params = try parser.parse(&arguments);
    try std.testing.expectEqualStrings("Argument1", params.options.arg_1.?);
}

test "parse single argument" {
    const prompt = "testcli Argument1";
    var arguments = std.mem.split(u8, prompt, " ");
    const allocator = std.heap.page_allocator;
    const ctx = CliContext{};
    const Params = struct {
        arg_1: ?[]const u8 = null,
    };
    const parser = CliParser(struct {}, Params){ .context = ctx, .allocator = allocator };
    const params = try parser.parse(&arguments);
    try std.testing.expectEqualStrings("Argument1", params.arguments.arg_1.?);
}

test "parse many arguments" {
    const prompt = "testcli Argument1 Argument2";
    var arguments = std.mem.split(u8, prompt, " ");
    const allocator = std.heap.page_allocator;
    const ctx = CliContext{};
    const Params = struct {
        arg_1: ?[]const u8 = null,
        arg_2: ?[]const u8 = null,
    };
    const parser = CliParser(struct {}, Params){ .context = ctx, .allocator = allocator };
    const params = try parser.parse(&arguments);
    try std.testing.expectEqualStrings("Argument1", params.arguments.arg_1.?);
}

test "parse integer argument" {
    const prompt = "testcli 42";
    var arguments = std.mem.split(u8, prompt, " ");
    const allocator = std.heap.page_allocator;
    const ctx = CliContext{};
    const Params = struct {
        arg_1: i32,
    };
    const parser = CliParser(struct {}, Params){ .context = ctx, .allocator = allocator };
    const params = try parser.parse(&arguments);
    try std.testing.expectEqual(42, params.arguments.arg_1);
}

test "parse float argument" {
    const prompt = "testcli 3.14";
    var arguments = std.mem.split(u8, prompt, " ");
    const allocator = std.heap.page_allocator;
    const ctx = CliContext{};
    const Params = struct {
        arg_1: f64,
    };
    const parser = CliParser(struct {}, Params){ .context = ctx, .allocator = allocator };
    const params = try parser.parse(&arguments);
    try std.testing.expectEqual(3.14, params.arguments.arg_1);
}

test "parse boolean flag" {
    const prompt = "testcli --enable";
    var arguments = std.mem.split(u8, prompt, " ");
    const allocator = std.heap.page_allocator;
    const ctx = CliContext{};
    const Options = struct {
        enable: bool,
    };
    const parser = CliParser(Options, struct {}){ .context = ctx, .allocator = allocator };
    const params = try parser.parse(&arguments);
    try std.testing.expect(params.options.enable);
}

test "parse choices valid case" {
    const allocator = std.heap.page_allocator;
    const ctx = CliContext{};
    const Choices = enum { choice_a, choice_b, choice_c };
    const Options = struct {
        choice: Choices,
    };
    const parser = CliParser(Options, struct {}){ .context = ctx, .allocator = allocator };

    const test_cases: [3][]const u8 = .{
        "testcli --choice choice_a",
        "testcli --choice choice_b",
        "testcli --choice choice_c",
    };
    const expected = [_]Choices{
        Choices.choice_a,
        Choices.choice_b,
        Choices.choice_c,
    };
    for (0.., test_cases) |i, prompt| {
        var arguments = std.mem.split(u8, prompt, " ");
        const params = try parser.parse(&arguments);
        try std.testing.expectEqual(expected[i], params.options.choice);
    }
}

test "parse choices invalid case" {
    const allocator = std.heap.page_allocator;
    const ctx = CliContext{};
    const Choices = enum { choice_a, choice_b, choice_c };
    const Options = struct {
        choice: Choices,
    };
    const parser = CliParser(Options, struct {}){ .context = ctx, .allocator = allocator };
    const prompt = "testcli --choice invalid";
    var arguments = std.mem.split(u8, prompt, " ");
    try std.testing.expectEqual(parser.parse(&arguments), CliError.InvalidChoice);
}

test "preprocess" {
    const allocator = std.heap.page_allocator;
    const prompt = "testcli --help";
    var arguments = std.mem.split(u8, prompt, " ");
    const params = try preprocess(allocator, &arguments);
    try std.testing.expect(params.options.help);
}
