/// Engine for the CLI utility
const std = @import("std");
const styling = @import("styling.zig");
const fmt = std.fmt;

const testing = std.testing;
const File = std.fs.File;
const Writer = File.Writer;
const Type = std.builtin.Type;
const Struct = Type.Struct;
const StructField = Type.StructField;
// types
const Allocator = std.mem.Allocator;
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

/// Documentation for an argument identified by `name`
/// as given by the application designer
pub const ArgInfo = struct {
    name: []const u8,
    help: ?[]const u8 = null,
};

pub const ArgInternalInfo = struct {
    name: []const u8,
    help: ?[]const u8 = null,
    default_value: ?[]const u8 = null,
};

pub const OptionInfo = struct {
    name: []const u8,
    short_name: ?[]const u8 = null,
    internal_name: ?[]const u8 = null,
    help: ?[]const u8 = null,
};

pub const OptionInternalInfo = struct {
    name: []const u8,
    short_name: []const u8 = undefined,
    internal_name: ?[]const u8 = undefined,
    help: ?[]const u8 = null,
    default_value: ?[]const u8 = null,
};

pub fn castDefaultValue(comptime T: type, comptime default_value: *const anyopaque) T {
    return @as(*T, @ptrCast(@constCast((@alignCast(default_value))))).*;
}

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
    DuplicatedOptionName,
    DuplicatedFlag,
};

// ShortFlag are passed with `-', LongFlag with '--',
const FlagType = enum {
    Argument,
    ShortFlag,
    LongFlag,
};

/// Formats the help hint for a set of choices given by enum fields
/// The choices are separated with '|'
pub fn formatChoices(fields: []const Type.EnumField) []const u8 {
    var choices: []const u8 = "";
    inline for (fields) |field| {
        choices = if (choices.len == 0) field.name else choices ++ "|" ++ field.name;
    }
    return choices;
}

/// Returns a friendely name for a given type `T`
/// which can be displayed as hint for the CLI user
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

test "get type name on enum" {
    const TestEnum = enum { ChoiceA, ChoiceB, ChoiceC };
    try std.testing.expectEqualStrings("ChoiceA|ChoiceB|ChoiceC", getTypeName(TestEnum));
}

/// Returns the format-string to use to print that type
pub fn formatDefaultValue(comptime T: type, comptime default_value: *const anyopaque) []const u8 {
    const default = comptime castDefaultValue(T, default_value);
    if (T == []const u8) {
        return default;
    }
    const format = comptime switch (@typeInfo(T)) {
        .Int, .Float => "{d}",
        // .Enum => |choices| formatChoices(choices.fields), //TODO fix
        .Enum => |e| {
            for (e.fields) |field| {
                if (@as(T, @enumFromInt(field.value)) == default) {
                    return field.name;
                }
                @compileError("Internal error: failed to find default for enum");
            }
        },
        .Optional => {
            if (default != null) {
                @compileError(
                    \\Optional fields are only allowed to have null as default value, 
                    \\ as default values other than null will never be applied
                );
            }
            return "none";
        },
        else => "{}",
    };
    return std.fmt.comptimePrint(format, .{default});
}

test "format default string values" {
    const Options = struct { name: []const u8 = "Bob" };
    // const options: Options = comptime .{};
    const option_field = std.meta.fields(Options)[0];
    const default_name = formatDefaultValue(option_field.type, option_field.default_value.?);
    try std.testing.expectEqualStrings("Bob", default_name);
}

test "format default non-string values" {
    const Options = struct { age: i32 = 42, height: f32 = 1.77, is_employee: bool = false };
    // const options: Options = comptime .{};
    const fields = std.meta.fields(Options);

    const default_age = formatDefaultValue(fields[0].type, fields[0].default_value.?);
    const default_height = formatDefaultValue(fields[1].type, fields[1].default_value.?);
    const default_is_employee = formatDefaultValue(fields[2].type, fields[2].default_value.?);

    try std.testing.expectEqualStrings("42", default_age);
    try std.testing.expectEqualStrings("1.77", default_height);
    try std.testing.expectEqualStrings("false", default_is_employee);
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

/// Converts a string value to the type `T`
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

/// Helper function making sure that the given is a struct
/// and returning its Struct variant.
/// Raises a compile time error with an appropriate message if not
pub fn ensureStruct(comptime T: type) Struct {
    switch (@typeInfo(T)) {
        .Struct => |s| return s,
        else => @compileError(
            std.fmt.comptimePrint("{} should be a defined as a struct", .{T}),
        ),
    }
}

pub fn fillOptionsInfo(
    comptime options: Struct,
    comptime options_info: []const OptionInfo,
) std.StaticStringMap(OptionInfo) {
    var final_options: [options.fields.len]OptionInfo = undefined;
    for (0.., options.fields) |i, field| {
        var option: OptionInfo = blk: {
            for (options_info) |opt| {
                if (opt.name == field.name) {
                    break :blk opt;
                }
            }
            break :blk .{};
        };
        defer final_options[i] = option;
        option.name = field.name;
    }
}
/// Extracts the option identified by `opt_name` from the list of options `options_info`
pub inline fn getOptionInfo(opt_name: []const u8, options_info: []const OptionInfo) ?OptionInfo {
    inline for (options_info) |opt| {
        if (std.mem.eql(u8, opt.name, opt_name)) {
            return opt;
        }
    }
    return null;
}
/// Extracts the option identified by `arg_name` from the list of options `args_info`
pub inline fn getArgInfo(arg_name: []const u8, args_info: []const ArgInfo) ?ArgInfo {
    inline for (args_info) |arg| {
        if (std.mem.eql(u8, arg.name, arg_name)) {
            return arg;
        }
    }
    return null;
}

/// Key-value pairs types for short flag maps
const _KVType = struct { []const u8, []const u8 };

pub fn _buildShortFlagMap(
    comptime struct_fields: []const StructField,
    comptime options_info: []const OptionInfo,
) CliError![struct_fields.len]_KVType {
    var kv_pairs: [struct_fields.len]_KVType = undefined;
    var kv_len: usize = 0;

    // pre-filling with the short flags that are set explicitly
    for (options_info) |opt| {
        if (opt.short_name) |flag| {
            kv_pairs[kv_len].@"0" = flag;
            kv_pairs[kv_len].@"1" = opt.short_name;
            kv_len += 1;
        }
    }

    inline for (struct_fields) |field| {
        var slice_index: usize = 1;
        const option_info = getOptionInfo(field.name, options_info);
        // Checking if the short flag has been explcitly set
        const explicit_short_flag = if (option_info) |opt| opt.short_name else null;
        // else starting from the first letter of the name
        var short_flag: []const u8 = explicit_short_flag orelse field.name[0..1];
        var is_unique = false;
        while (!is_unique) {
            // checking if that short flag is unique
            for (kv_pairs[0..kv_len]) |kv| {
                if (std.mem.eql(u8, kv.@"0", short_flag)) {
                    // flag already exists
                    break;
                }
            } else {
                is_unique = true;
                break;
            }
            // if not unique, taking on more letter of the name
            if (explicit_short_flag) |_| {
                return CliError.DuplicatedFlag;
            }
            slice_index += 1;
            if (slice_index == field.name.len) {
                return CliError.DuplicatedOptionName;
            }
            short_flag = field.name[0..slice_index];
        }
        kv_pairs[kv_len].@"0" = short_flag;
        kv_pairs[kv_len].@"1" = field.name;
        kv_len += 1;
    }
    return kv_pairs;
}

/// Parses the options documentation and the option struct fields definition,
/// and builds a hashmap associating each parameter name to its short flag
/// if an explicit flag was passed by in the option doc, ensures uniqueness of that flag
/// and uses it as such
/// If not, finds the shortest flag that can be used without duplication.
/// In that case, options defined first will get the shortest flag
/// (e.g.) if you have options `port` and `platform`,
/// if port is defined before platform it will flag `-p`
/// while platform will get `-pl`
pub fn buildShortFlagMap(
    comptime struct_fields: []const StructField,
    comptime options_info: []const OptionInfo,
    comptime reverse: bool,
) CliError!std.StaticStringMap([]const u8) {
    const kv_pairs = comptime try _buildShortFlagMap(struct_fields, options_info);
    if (!reverse) {
        return std.StaticStringMap([]const u8).initComptime(kv_pairs);
    }
    var reversed_kv_pairs: [kv_pairs.len]_KVType = undefined;
    for (0.., kv_pairs) |i, kv| {
        reversed_kv_pairs[i].@"0" = kv.@"1";
        reversed_kv_pairs[i].@"1" = kv.@"0";
    }
    return std.StaticStringMap([]const u8).initComptime(reversed_kv_pairs);
}

test "build short flag map" {
    const TestOptions = struct {
        abcde: bool, // expects -a
        abd: bool, // expects -ab
        abcfg: bool, // expects -abc
        cba: bool, // expects -c
    };
    const OptionsStruct = ensureStruct(TestOptions);
    const short_flag_map = try buildShortFlagMap(OptionsStruct.fields, &.{}, false);
    try std.testing.expectEqualStrings("abcde", short_flag_map.get("a").?);
    try std.testing.expectEqualStrings("abd", short_flag_map.get("ab").?);
    try std.testing.expectEqualStrings("abcfg", short_flag_map.get("abc").?);
    try std.testing.expectEqualStrings("cba", short_flag_map.get("c").?);
}

/// Given the documentation given by `options_info` and the fields
/// of the struct used as container for options `options_fields`
/// Infers the option information from the struct itself (e.g. default value)
/// to build the internal information list
pub fn parseOptionInfo(
    comptime option_fields: []const StructField,
    comptime options_info: []const OptionInfo,
) CliError![option_fields.len]OptionInternalInfo {
    var out: [option_fields.len]OptionInternalInfo = undefined;
    const flag_map = try buildShortFlagMap(option_fields, options_info, true);
    for (0.., option_fields) |i, field| {
        const default_value = field.default_value orelse @compileError(
            \\All options should have a default !
        );
        var internal_opt = OptionInternalInfo{
            .name = field.name,
            .default_value = formatDefaultValue(field.type, default_value),
        };
        if (getOptionInfo(field.name, options_info)) |info| {
            internal_opt.help = info.help;
        }
        internal_opt.short_name = flag_map.get(field.name).?;
        out[i] = internal_opt;
    }
    return out;
}

test "parse option defaults" {
    const TestOptions = struct {
        abcde: u32 = 42, // expects -a
        abd: bool = false, // expects -ab
        abcfg: f32 = 3.14, // expects -abc
        cba: []const u8 = "Hello", // expects -c
    };
    const OptionsStruct = ensureStruct(TestOptions);
    const options_info = comptime try parseOptionInfo(OptionsStruct.fields, &.{});
    try std.testing.expectEqualStrings("42", options_info[0].default_value.?);
    try std.testing.expectEqualStrings("false", options_info[1].default_value.?);
    try std.testing.expectEqualStrings("3.14", options_info[2].default_value.?);
    try std.testing.expectEqualStrings("Hello", options_info[3].default_value.?);
}

pub fn buildOptionInfoMap(
    comptime option_fields: []const StructField,
    comptime options_info: []const OptionInfo,
) CliError!std.StaticStringMap(OptionInternalInfo) {
    const options_parsed_info = try parseOptionInfo(option_fields, options_info);
    var kv_pairs: [options_parsed_info.len]struct { []const u8, OptionInternalInfo } = undefined;
    for (0.., options_parsed_info) |i, opt| {
        kv_pairs[i].@"0" = opt.name;
        kv_pairs[i].@"1" = opt;
    }
    return std.StaticStringMap(OptionInternalInfo).initComptime(kv_pairs);
}

test "option info map" {
    const TestOptions = struct {
        abcde: u32 = 42, // expects -a
        abd: bool = false, // expects -ab
        abcfg: f32 = 3.14, // expects -abc
        cba: []const u8 = "Hello", // expects -c
    };
    const OptionsStruct = ensureStruct(TestOptions);
    const options_info = comptime try buildOptionInfoMap(OptionsStruct.fields, &.{});

    try std.testing.expectEqualStrings(options_info.get("abcde").?.short_name, "a");
}

// pub fn showDefaults(comptime T: type, writer: RichWriter, default: anyopaque) void {}

const CliContext = struct {
    opts: ?type = null,
    args: ?type = null,
    opts_info: []const OptionInfo = &.{},
    args_info: []const ArgInfo = &.{},
    name: ?[]const u8 = null,
    comptime welcome_msg: ?[]const u8 = null,
};

/// A struct builder containing the parsed arguments passed by the user in command-line
/// Provides standalone methods for running the parsing process
/// `ctx` should provide all the information to layout the parser at comptime
pub fn CliParser(comptime ctx: CliContext) type {
    return struct {
        const OptionT = ctx.opts orelse struct {};
        const ArgT = ctx.args orelse struct {};
        const Self = @This();

        args: ArgT,
        options: OptionT,
        builtin: BuiltinOptions,

        // Making sure that the types are structs and extracting
        // their meta struct
        const OptionSt = ensureStruct(OptionT);
        const ArgSt = ensureStruct(ArgT);
        const BuiltinSt = ensureStruct(BuiltinOptions);

        const flag_to_name_map = buildShortFlagMap(OptionSt.fields, ctx.opts_info, true);
        const name_to_flag_map = buildShortFlagMap(OptionSt.fields, ctx.opts_info, false);
        const options_info_map = buildOptionInfoMap(OptionSt.fields, ctx.opts_info) catch unreachable;

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

        pub fn hasArguments() bool {
            return (ctx.args != null);
        }

        pub fn hasOptions() bool {
            return (ctx.opts != null);
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

        pub fn parseFlag(self: *Self, arg_name: []const u8) CliError!void {
            setArgFromString(
                BuiltinOptions,
                arg_name,
                "true",
                &(self.builtin),
            ) catch {
                try setArgFromString(
                    OptionT,
                    arg_name,
                    "true",
                    &(self.options),
                );
            };
        }

        pub fn parseArg(
            self: *Self,
            arg_name: []const u8,
            arg_value: []const u8,
            is_option: bool,
        ) CliError!void {
            if (is_option) {
                return setArgFromString(
                    BuiltinOptions,
                    arg_name,
                    arg_value,
                    &(self.builtin),
                ) catch {
                    try setArgFromString(
                        OptionT,
                        arg_name,
                        arg_value,
                        &(self.options),
                    );
                };
            }
            try setArgFromString(
                ArgT,
                arg_name,
                arg_value,
                &(self.args),
            );
        }

        pub fn introspectArgName(arg_idx: usize) CliError![]const u8 {
            inline for (0.., ArgSt.fields) |i, field| {
                if (i == arg_idx) {
                    return field.name;
                }
            }
            return CliError.TooManyArguments;
        }

        pub fn parse(arg_it: anytype) CliError!Self {
            var params: Self = undefined;
            initOptionals(OptionT, &(params.options));
            initOptionals(ArgT, &(params.args));

            var is_option: bool = false;
            var flag_type: ?FlagType = null;
            var current_arg_name: []const u8 = "";
            var arg_idx: usize = 0;

            // If no explicit client name was passed,using process name
            const process_name: []const u8 = arg_it.next() orelse return CliError.EmptyArguments;
            params.builtin.cli_name = ctx.name orelse getPathBasename(process_name);
            var next_arg = arg_it.next();
            var consume = true;

            while (next_arg) |arg| {
                // consume will be set to false if we have an argument
                defer next_arg = if (consume) arg_it.next() else next_arg;

                if (flag_type) |_| {
                    consume = true;
                    defer flag_type = null;
                    try params.parseArg(
                        current_arg_name,
                        arg,
                        is_option,
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
                        current_arg_name = try introspectArgName(arg_idx);
                        arg_idx += 1;
                        consume = false;
                    },
                    .ShortFlag => {
                        is_option = true;
                        current_arg_name = if (options_info_map.get(arg[arg_name_start_idx..])) |opt| opt.name else return CliError.UnknownOption;
                        if (try isFlag(current_arg_name)) {
                            try params.parseFlag(current_arg_name);
                        }
                    },
                    else => {
                        is_option = true;
                        current_arg_name = arg[arg_name_start_idx..];
                        if (try isFlag(current_arg_name)) {
                            try params.parseFlag(current_arg_name);
                        }
                    },
                }
            }
            return params;
        }

        pub fn emitWelcomeMessage(self: Self, writer: *const Writer) !void {
            const rich = RichWriter{ .writer = writer };
            if (self.builtin.cli_name) |name| {
                const welcome_msg = ctx.welcome_msg orelse default_welcome_message;
                rich.richPrint(welcome_msg, Style.Header1, .{name});
                rich.print("\n", .{});
                return;
            }
            panic(
                \\No client name given and the parser has not run,
                \\ cannot format welcome message.
            , .{});
        }

        pub fn emitHelp(self: Self, writer: *const Writer) !void {
            // TODO: divide this into smaller functions
            // var flag_map = self.buildShortFlagMap(false);
            const rich = RichWriter{ .writer = writer };
            rich.richPrint("===== Usage =====", .Header2, .{});
            // Showing typical usage
            rich.richPrint(">>> {s}", .Field, .{self.builtin.cli_name.?});
            inline for (std.meta.fields(ArgT)) |field| {
                rich.richPrint(" {{{s}}}  ", .Field, .{field.name});
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
                    rich.richPrint(
                        "{s}: {s}",
                        .Entry,
                        .{
                            field.name,
                            getTypeName(field.type),
                        },
                    );
                    if (getArgInfo(field.name, ctx.args_info)) |arg| {
                        if (arg.help) |help| {
                            rich.print("    {s}\n", .{help});
                        }
                    }
                }
                rich.write("\n");
            }
            if (hasOptions()) {
                rich.richPrint(
                    "==== Options ====",
                    .Header2,
                    .{},
                );
                inline for (std.meta.fields(OptionT)) |field| {
                    const opt_internal_info = options_info_map.get(field.name) orelse panic(
                        "Internal error: option {s} internal info has not been extracted properly",
                        .{field.name},
                    );
                    rich.richPrint(
                        "-{s}, --{s}: {s}",
                        .Field,
                        .{
                            opt_internal_info.short_name,
                            opt_internal_info.name,
                            getTypeName(field.type),
                        },
                    );
                    if (opt_internal_info.default_value) |default| {
                        rich.richPrint("    [default:{s}]", .Field, .{default});
                    }
                    rich.write("\n");
                    if (getOptionInfo(field.name, ctx.opts_info)) |opt| {
                        if (opt.help) |help| {
                            rich.print("    {s}\n", .{help});
                        }
                    }
                }
            }
        }

        pub fn runStandalone() !?Self {
            var args_it = std.process.args();
            const writer = std.io.getStdOut().writer();
            const params = try Self.parse(&args_it);
            std.debug.assert(params.builtin.cli_name != null);
            try params.emitWelcomeMessage(&writer);
            if (params.builtin.help) {
                try params.emitHelp(&writer);
                return null;
            }
            return params;
        }
    };
}

pub const BuiltinOptions = struct {
    help: bool = false,
    cli_name: ?[]const u8 = null,
};
// pub const BuiltinParser = CliParser(.{ .options = BuiltinOptions });

// Basic test case that only uses options and does not require casting
test "parse with string parameters only" {
    const prompt = "testcli --arg_1 Argument1";
    var arguments = std.mem.split(u8, prompt, " ");
    // const allocator = std.heap.page_allocator;
    const Options = struct {
        arg_1: ?[]const u8 = null,
    };
    const params = try CliParser(.{ .opts = Options }).parse(&arguments);
    try std.testing.expectEqualStrings("Argument1", params.options.arg_1.?);
}

test "parse single argument" {
    const prompt = "testcli Argument1";
    var arguments = std.mem.split(u8, prompt, " ");
    const Args = struct {
        arg_1: ?[]const u8,
    };
    const params = try CliParser(.{ .args = Args }).parse(&arguments);
    try std.testing.expectEqualStrings("Argument1", params.args.arg_1.?);
}

test "parse many arguments" {
    const prompt = "testcli Argument1 Argument2";
    var arguments = std.mem.split(u8, prompt, " ");
    const Args = struct {
        arg_1: ?[]const u8 = null,
        arg_2: ?[]const u8 = null,
    };
    const params = try CliParser(.{ .args = Args }).parse(&arguments);
    try std.testing.expectEqualStrings("Argument1", params.args.arg_1.?);
    try std.testing.expectEqualStrings("Argument2", params.args.arg_2.?);
}

test "parse integer argument" {
    const prompt = "testcli 42";
    var arguments = std.mem.split(u8, prompt, " ");
    const Args = struct {
        arg_1: i32,
    };
    const params = try CliParser(.{ .args = Args }).parse(&arguments);
    try std.testing.expectEqual(42, params.args.arg_1);
}

test "parse float argument" {
    const prompt = "testcli 3.14";
    var arguments = std.mem.split(u8, prompt, " ");
    const Args = struct {
        arg_1: f64,
    };
    const params = try CliParser(.{ .args = Args }).parse(&arguments);
    try std.testing.expectEqual(3.14, params.args.arg_1);
}

test "parse boolean flag" {
    const prompt = "testcli --enable";
    var arguments = std.mem.split(u8, prompt, " ");
    const Options = struct {
        enable: bool = false,
    };
    const params = try CliParser(.{ .opts = Options }).parse(&arguments);
    try std.testing.expect(params.options.enable);
}

test "parse choices valid case" {
    const Choices = enum { choice_a, choice_b, choice_c };
    const Options = struct {
        choice: Choices = Choices.choice_a,
    };

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
        const params = try CliParser(.{ .opts = Options }).parse(&arguments);
        try std.testing.expectEqual(expected[i], params.options.choice);
    }
}

test "parse choices invalid case" {
    const Choices = enum { choice_a, choice_b, choice_c };
    const Options = struct {
        choice: Choices = Choices.choice_a,
    };
    const prompt = "testcli --choice invalid";
    var arguments = std.mem.split(u8, prompt, " ");
    try std.testing.expectEqual(CliParser(.{ .opts = Options }).parse(&arguments), CliError.InvalidChoice);
}

test "parse help" {
    const prompt = "testcli --help";
    var arguments = std.mem.split(u8, prompt, " ");

    const params = try CliParser(.{}).parse(&arguments);
    try std.testing.expect(params.builtin.help);
}
