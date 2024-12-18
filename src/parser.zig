/// Engine for the CLI utility
const std = @import("std");
const testing = std.testing;
const File = std.fs.File;
const Writer = File.Writer;
const Type = std.builtin.Type;

// types
const Allocator = std.mem.Allocator;
// const ArgIterator = std.process.ArgIterator;
const ArgIterator = anyopaque;

const default_welcome_message = "Welcome to {s} !\n";

pub const CliContext = struct {
    name: ?[]const u8 = null,
    welcome_msg: ?[]const u8 = null,
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
    InvalidBooleanValue,
};

// ShortFlag are passed with `-', LongFlag with '--',
const FlagType = enum {
    Argument,
    ShortFlag,
    LongFlag,
};

pub const NoArguments = struct {};
pub const NoOptions = struct {};

pub fn formatChoices(fields: []const Type.EnumField) []const u8 {
    var choices: []const u8 = "";
    inline for (fields) |field| {
        choices = if (choices.len == 0) field.name else choices ++ "|" ++ field.name;
    }
    return choices;
}

pub fn getTypeName(comptime T: type) []const u8 {
    if (T == []const u8) {
        return "text";
    }
    const type_description = comptime switch (@typeInfo(T)) {
        .Bool => "flag",
        .Int => "integer",
        .Float => "float",
        .Enum => |choices| formatChoices(choices.fields),
        .Optional => |opt| "(Optional) " ++ getTypeName(opt.child),
        else => unreachable,
    };
    return type_description;
}

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
        .Bool => |_| {
            if (std.mem.eql(u8, "true", value_str)) {
                return true;
            }
            if (std.mem.eql(u8, "false", value_str)) {
                return false;
            }
            return CliError.InvalidBooleanValue;
        },
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
        builtin: *BuiltinOptions,
    };
}

pub fn CliParser(comptime OptionT: type, comptime ArgT: type) type {
    return struct {
        context: CliContext,
        allocator: Allocator,

        const Params = CliParams(OptionT, ArgT);

        const Self = @This();

        const OptionSt = switch (@typeInfo(OptionT)) {
            .Struct => |st| st,
            else => unreachable,
        };

        const ArgSt = switch (@typeInfo(OptionT)) {
            .Struct => |st| st,
            else => unreachable,
        };

        fn isFlag(arg_name: []const u8) CliError!bool {
            inline for ([_]type{ OptionT, ArgT, BuiltinOptions }) |container_type| {
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

        pub fn buildShortFlagMap(self: Self, reverse: bool) std.StringHashMap([]const u8) {
            var map = std.StringHashMap([]const u8).init(self.allocator);
            var reversed_map = std.StringHashMap([]const u8).init(self.allocator);

            inline for (OptionSt.fields) |field| {
                var slice_index: usize = 1;
                var slice = field.name[0..slice_index];
                while (reversed_map.contains(slice)) {
                    slice_index += 1;
                    slice = field.name[0..slice_index];
                }
                reversed_map.put(slice, field.name) catch unreachable;
                map.put(field.name, slice) catch unreachable;
            }
            return if (reverse) reversed_map else map;
        }

        pub fn hasArguments() bool {
            return ArgT != NoArguments;
        }

        pub fn hasOptions() bool {
            return OptionT != NoOptions;
        }
        pub fn setArgFromString(comptime T: type, arg_name: []const u8, arg_value: []const u8, container: *T) CliError!void {
            const container_info = @typeInfo(T);
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

        pub fn parseFlag(arg_name: []const u8, params: Params) CliError!void {
            setArgFromString(
                BuiltinOptions,
                arg_name,
                "true",
                params.builtin,
            ) catch {
                try setArgFromString(
                    OptionT,
                    arg_name,
                    "true",
                    params.options,
                );
            };
        }

        pub fn parseArg(
            arg_name: []const u8,
            arg_value: []const u8,
            is_option: bool,
            params: Params,
        ) CliError!void {
            if (is_option) {
                return setArgFromString(
                    BuiltinOptions,
                    arg_name,
                    arg_value,
                    params.builtin,
                ) catch {
                    try setArgFromString(
                        OptionT,
                        arg_name,
                        arg_value,
                        params.options,
                    );
                };
            }
            try setArgFromString(
                ArgT,
                arg_name,
                arg_value,
                params.arguments,
            );
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

        pub fn parse(self: Self, arg_it: anytype) CliError!Params {
            const options: *OptionT = self.allocator.create(OptionT) catch return CliError.MemoryError;
            const arguments: *ArgT = self.allocator.create(ArgT) catch return CliError.MemoryError;
            const builtin_options = self.allocator.create(BuiltinOptions) catch return CliError.MemoryError;

            var short_flags = self.buildShortFlagMap(true);
            defer short_flags.deinit();
            initOptionals(OptionT, options);
            initOptionals(ArgT, arguments);

            const params = Params{
                .options = options,
                .arguments = arguments,
                .builtin = builtin_options,
            };

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

                if (flag_type) |_| {
                    consume = true;
                    defer flag_type = null;
                    try parseArg(
                        current_arg_name,
                        arg,
                        is_option,
                        params,
                    );

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
                    .ShortFlag => {
                        is_option = true;
                        current_arg_name = short_flags.get(arg[arg_name_start_idx..]) orelse return CliError.UnknownOption;
                        if (try isFlag(current_arg_name)) {
                            try parseFlag(current_arg_name, params);
                        }
                    },
                    else => {
                        is_option = true;
                        current_arg_name = arg[arg_name_start_idx..];
                        if (try isFlag(current_arg_name)) {
                            try parseFlag(current_arg_name, params);
                        }
                    },
                }
            }
            return params;
        }

        pub fn emitHelp(self: Self, writer: Writer) !void {
            var flag_map = self.buildShortFlagMap(false);
            defer flag_map.deinit();
            _ = try writer.write("===== Usage =====\n\n");
            if (hasArguments()) {
                _ = try writer.write(
                    \\Arguments
                    \\---------
                );
                _ = try writer.write("\n");
                inline for (std.meta.fields(ArgT)) |field| {
                    _ = try writer.write(field.name);
                    _ = try writer.write(": ");
                    _ = try writer.write(getTypeName(field.type));
                    _ = try writer.write("\n");
                }
            }
            _ = try writer.write("\n");
            if (hasOptions()) {
                _ = try writer.write(
                    \\Options
                    \\-------
                );
                _ = try writer.write("\n");
                inline for (std.meta.fields(OptionT)) |field| {
                    _ = try writer.write("-");
                    _ = try writer.write(flag_map.get(field.name).?);
                    _ = try writer.write(", ");
                    _ = try writer.write("--");
                    _ = try writer.write(field.name);
                    _ = try writer.write(": ");
                    _ = try writer.write(getTypeName(field.type));
                    _ = try writer.write("\n");
                }
            }
        }

        pub fn run_standalone() !?Params {
            const allocator = std.heap.page_allocator;
            var args_it = std.process.args();
            const writer = std.io.getStdOut().writer();
            const ctx = CliContext{};
            const parser = Self{ .context = ctx, .allocator = allocator };
            const params = try parser.parse(&args_it);

            if (params.builtin.help) {
                // _ = try writer.write("Pass your name as argument and optionally your surname with --surname !\n");
                try parser.emitHelp(writer);
                return null;
            }
            return params;
        }
    };
}

pub const BuiltinOptions = struct {
    help: bool,
};
pub const BuiltinParser = CliParser(BuiltinOptions, NoArguments);

// Basic test case that only uses options and does not require casting
test "parse with string parameters only" {
    const prompt = "testcli --arg_1 Argument1";
    var arguments = std.mem.split(u8, prompt, " ");
    const allocator = std.heap.page_allocator;
    const ctx = CliContext{};
    const Params = struct {
        arg_1: ?[]const u8,
    };
    const parser = CliParser(Params, NoArguments){ .context = ctx, .allocator = allocator };
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
    const parser = CliParser(NoOptions, Params){ .context = ctx, .allocator = allocator };
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
    const parser = CliParser(NoOptions, Params){ .context = ctx, .allocator = allocator };
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
    const parser = CliParser(NoOptions, Params){ .context = ctx, .allocator = allocator };
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
    const parser = CliParser(NoOptions, Params){ .context = ctx, .allocator = allocator };
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
    const parser = CliParser(Options, NoArguments){ .context = ctx, .allocator = allocator };
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
    const parser = CliParser(Options, NoArguments){ .context = ctx, .allocator = allocator };

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
    const parser = CliParser(Options, NoArguments){
        .context = ctx,
        .allocator = allocator,
    };
    const prompt = "testcli --choice invalid";
    var arguments = std.mem.split(u8, prompt, " ");
    try std.testing.expectEqual(parser.parse(&arguments), CliError.InvalidChoice);
}

test "parse help" {
    const allocator = std.heap.page_allocator;
    const prompt = "testcli --help";
    const ctx = CliContext{};

    var arguments = std.mem.split(u8, prompt, " ");
    const parser = CliParser(NoOptions, NoOptions){
        .context = ctx,
        .allocator = allocator,
    };
    const params = try parser.parse(&arguments);
    try std.testing.expect(params.builtin.help);
}

test "get type name on enum" {
    const TestEnum = enum { ChoiceA, ChoiceB, ChoiceC };
    try std.testing.expectEqualStrings("ChoiceA|ChoiceB|ChoiceC", getTypeName(TestEnum));
}

test "build short flag map" {
    const allocator = std.heap.page_allocator;
    const ctx = CliContext{};

    const TestOptions = struct {
        abcde: bool, // expects -a
        abd: bool, // expects -ab
        abcfg: bool, // expects -abc
        cba: bool, // expects -c
    };
    const parser = CliParser(TestOptions, NoOptions){
        .context = ctx,
        .allocator = allocator,
    };
    const short_flag_map = parser.buildShortFlagMap(false);
    try std.testing.expectEqualStrings("a", short_flag_map.get("abcde").?);
    try std.testing.expectEqualStrings("ab", short_flag_map.get("abd").?);
    try std.testing.expectEqualStrings("abc", short_flag_map.get("abcfg").?);
    try std.testing.expectEqualStrings("c", short_flag_map.get("cba").?);
}
