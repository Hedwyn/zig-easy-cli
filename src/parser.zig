/// Engine for the CLI utility
const std = @import("std");
const styling = @import("styling.zig");
const fmt = std.fmt;

const testing = std.testing;
const File = std.fs.File;
const Writer = File.Writer;
const Type = std.builtin.Type;
const Struct = Type.Struct;
// types
const Allocator = std.mem.Allocator;
// const ArgIterator = std.process.ArgIterator;
const ArgIterator = anyopaque;
const panic = std.debug.panic;

const RichWriter = styling.RichWriter;
const Style = styling.Style;

const default_welcome_message = "Welcome to {s} !";

/// Returns the last member of a path separated by `/`
pub fn getPathBasename(path: []const u8) []const u8 {
    // TODO: windows
    var basename = path;
    var split_it = std.mem.split(u8, basename, "/");
    while (split_it.next()) |chunk| {
        basename = chunk;
    }
    return basename;
}

pub const ArgInfo = struct {
    name: []const u8,
    help: ?[]const u8 = null,
};

pub const OptionInfo = struct {
    name: []const u8,
    short_name: ?[]const u8 = null,
    internal_name: ?[]const u8 = null,
    help: ?[]const u8 = null,
};

pub const CliContext = struct {
    name: ?[]const u8 = null,
    comptime welcome_msg: ?[]const u8 = null,
    options_info: []const OptionInfo = &.{},
    arg_info: []const ArgInfo = &.{},

    pub fn getOptionInfo(self: CliContext, option_name: []const u8) ?OptionInfo {
        for (self.options_info) |opt| {
            if (std.mem.eql(u8, opt.name, option_name)) {
                return opt;
            }
        }
        return null;
    }

    pub fn getArgInfo(self: CliContext, arg_name: []const u8) ?ArgInfo {
        for (self.arg_info) |arg| {
            if (std.mem.eql(u8, arg.name, arg_name)) {
                return arg;
            }
        }
        return null;
    }
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

///! Asserts that type is a struct and returns its Struct variant.
pub fn ensureStruct(comptime T: type) Struct {
    switch (@typeInfo(T)) {
        .Struct => |s| return s,
        else => std.debug.panic("Type {} should be a struct", .{T}),
    }
}

pub fn CliParser(comptime OptionT: type, comptime ArgT: type) type {
    return struct {
        context: CliContext,
        allocator: Allocator,

        const Params = CliParams(OptionT, ArgT);

        const Self = @This();

        // Making sure that the types are structs and extracting
        // their meta struct
        const OptionSt = ensureStruct(OptionT);
        const ArgSt = ensureStruct(ArgT);
        const BuiltinSt = ensureStruct(BuiltinOptions);

        fn isFlag(arg_name: []const u8) CliError!bool {
            inline for ([_]Struct{ OptionSt, ArgSt, BuiltinSt }) |type_st| {
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

        pub fn buildShortFlagMap(self: Self, use_short_name: bool) std.StringHashMap(OptionInfo) {
            var map = std.StringHashMap(OptionInfo).init(self.allocator);
            var reversed_map = std.StringHashMap(OptionInfo).init(self.allocator);

            inline for (OptionSt.fields) |field| {
                var slice_index: usize = 1;
                var slice = field.name[0..slice_index];
                var short_flag: ?[]const u8 = null;
                var option_info: ?OptionInfo = null;
                // Checking if there's an entry in the documentation for this option
                if (self.context.getOptionInfo(field.name)) |opt| {
                    option_info = opt;
                    short_flag = opt.short_name;
                } else {
                    option_info = OptionInfo{ .name = field.name };
                }
                if (short_flag == null) {
                    // building flag
                    while (reversed_map.contains(slice)) {
                        slice_index += 1;
                        slice = field.name[0..slice_index];
                    }
                    short_flag = slice;
                    option_info.?.short_name = short_flag;
                }
                reversed_map.put(short_flag.?, option_info.?) catch unreachable;
                map.put(field.name, option_info.?) catch unreachable;
            }
            return if (use_short_name) reversed_map else map;
        }

        pub fn hasArguments() bool {
            return ArgT != NoArguments;
        }

        pub fn hasOptions() bool {
            return OptionT != NoOptions;
        }
        pub fn setArgFromString(comptime T: type, arg_name: []const u8, arg_value: []const u8, container: *T) CliError!void {
            const struct_info = ensureStruct(T);
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
            inline for (0.., ArgSt.fields) |i, field| {
                if (i == arg_idx) {
                    return field.name;
                }
            }
            return CliError.TooManyArguments;
        }

        pub fn parse(self: *Self, arg_it: anytype) CliError!Params {
            const options: *OptionT = self.allocator.create(OptionT) catch return CliError.MemoryError;
            const arguments: *ArgT = self.allocator.create(ArgT) catch return CliError.MemoryError;
            const builtin_options = self.allocator.create(BuiltinOptions) catch return CliError.MemoryError;

            var option_info_map = self.buildShortFlagMap(true);
            defer option_info_map.deinit();
            initOptionals(OptionT, options);
            initOptionals(ArgT, arguments);

            const params = Params{
                .options = options,
                .arguments = arguments,
                .builtin = builtin_options,
            };

            var is_option: bool = false;
            var flag_type: ?FlagType = null;
            var current_arg_name: []const u8 = "";
            var arg_idx: usize = 0;

            // If no explicit client name was passed,using process name
            const process_name: []const u8 = arg_it.next() orelse return CliError.EmptyArguments;
            self.context.name = self.context.name orelse getPathBasename(process_name);
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
                        current_arg_name = if (option_info_map.get(arg[arg_name_start_idx..])) |opt| opt.name else return CliError.UnknownOption;
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

        pub fn emitWelcomeMessage(self: Self, writer: *const Writer) !void {
            const rich = RichWriter{ .writer = writer };
            if (self.context.name) |name| {
                const welcome_msg = self.context.welcome_msg orelse default_welcome_message;
                rich.print("\n", .{});
                rich.richPrint(welcome_msg, Style.Header1, .{name});
                rich.print("\n", .{});
                return;
            }
            @panic(
                \\No client name given and the parser has not run,
                \\ cannot format welcome message.
            );
        }

        pub fn emitHelp(self: Self, writer: *const Writer) !void {
            // TODO: divide this into smaller functions
            var flag_map = self.buildShortFlagMap(false);
            const rich = RichWriter{ .writer = writer };
            defer flag_map.deinit();
            rich.richPrint("===== Usage =====", .Header2, .{});
            // Showing typical usage
            rich.print(">>> {s}", .{self.context.name.?});
            inline for (std.meta.fields(ArgT)) |field| {
                rich.print(" {{{s}}}  ", .{field.name});
            }
            rich.write("\n\n");

            // Formatting argument doc
            if (hasArguments()) {
                rich.richPrint(
                    "=== Arguments ===",
                    .Header2,
                    .{},
                );
                inline for (std.meta.fields(ArgT)) |field| {
                    rich.print("{s}: {s}\n", .{
                        field.name,
                        getTypeName(field.type),
                    });
                    if (self.context.getArgInfo(field.name)) |arg| {
                        if (arg.help) |help| {
                            rich.print("    {s}\n", .{help});
                        }
                    }
                }
            }
            if (hasOptions()) {
                rich.richPrint(
                    "==== Options ====",
                    .Header2,
                    .{},
                );
                inline for (std.meta.fields(OptionT)) |field| {
                    rich.print("-{s}, --{s}: {s}\n", .{
                        flag_map.get(field.name).?.short_name.?,
                        field.name,
                        getTypeName(field.type),
                    });
                    if (self.context.getOptionInfo(field.name)) |opt| {
                        if (opt.help) |help| {
                            rich.print("    {s}\n", .{help});
                        }
                    }
                }
            }
        }

        pub fn runStandalone(context: CliContext) !?Params {
            const allocator = std.heap.page_allocator;
            var args_it = std.process.args();
            const writer = std.io.getStdOut().writer();
            var parser = Self{ .context = context, .allocator = allocator };
            const params = try parser.parse(&args_it);
            std.debug.assert(parser.context.name != null);
            try parser.emitWelcomeMessage(&writer);
            if (params.builtin.help) {
                try parser.emitHelp(&writer);
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
    var parser = CliParser(Params, NoArguments){ .context = ctx, .allocator = allocator };
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
    var parser = CliParser(NoOptions, Params){ .context = ctx, .allocator = allocator };
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
    var parser = CliParser(NoOptions, Params){ .context = ctx, .allocator = allocator };
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
    var parser = CliParser(NoOptions, Params){ .context = ctx, .allocator = allocator };
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
    var parser = CliParser(NoOptions, Params){ .context = ctx, .allocator = allocator };
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
    var parser = CliParser(Options, NoArguments){ .context = ctx, .allocator = allocator };
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
    var parser = CliParser(Options, NoArguments){ .context = ctx, .allocator = allocator };

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
    var parser = CliParser(Options, NoArguments){
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
    var parser = CliParser(NoOptions, NoOptions){
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
    var parser = CliParser(TestOptions, NoOptions){
        .context = ctx,
        .allocator = allocator,
    };
    const short_flag_map = parser.buildShortFlagMap(false);
    try std.testing.expectEqualStrings("a", short_flag_map.get("abcde").?.short_name.?);
    try std.testing.expectEqualStrings("ab", short_flag_map.get("abd").?.short_name.?);
    try std.testing.expectEqualStrings("abc", short_flag_map.get("abcfg").?.short_name.?);
    try std.testing.expectEqualStrings("c", short_flag_map.get("cba").?.short_name.?);
}
