/// Engine for the CLI utility
const std = @import("std");
const log = std.log;
const styling = @import("styling.zig");
const fmt = std.fmt;

const testing = std.testing;
const File = std.fs.File;
const Writer = File.Writer;
const Type = std.builtin.Type;
const Struct = Type.Struct;
const StructField = Type.StructField;
const UnionField = Type.UnionField;
// types
const Allocator = std.mem.Allocator;
const ArgIterator = anyopaque;
const panic = std.debug.panic;

const RichWriter = styling.RichWriter;
const Style = styling.Style;

const default_welcome_message = "Welcome to {s} !";

var global_level: log.Level = .info;

/// Set this function as your log handler if you want
/// zig-easy-cli to manage your logs
pub fn logHandler(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(global_level)) {
        return;
    }
    _ = scope;
    const prefix = "[" ++ comptime level.asText() ++ "] ";

    // Print the message to stderr, silently ignoring any errors
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    const stderr = std.io.getStdErr().writer();
    nosuspend stderr.print(prefix ++ format ++ "\n", args) catch return;
}

/// Returns the last member of a path separated by `/`
pub fn getPathBasename(path: []const u8) []const u8 {
    // TODO: windows
    var basename = path;
    var split_it = std.mem.splitSequence(u8, basename, "/");
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

/// Allows configuring how the CLI should handle
/// your options and also to add documentation bits
pub const OptionInfo = struct {
    name: []const u8,
    short_name: ?[]const u8 = null,
    internal_name: ?[]const u8 = null,
    help: ?[]const u8 = null,
    hidden: bool = false,
};

/// Internal struct used for option info,
/// which expands `OptionInfo` with fields
/// that are required for the comp-time logic
/// but do not need to be passed explicitly by
/// the CLI developer
pub const OptionInternalInfo = struct {
    name: []const u8,
    short_name: []const u8 = undefined,
    internal_name: ?[]const u8 = undefined,
    help: ?[]const u8 = null,
    default_value: ?[]const u8 = null,
    hidden: bool = false,
};

/// Tries converting a default value for a field to its expected type
pub fn castDefaultValue(comptime T: type, comptime default_value: *const anyopaque) T {
    return @as(*T, @ptrCast(@constCast((@alignCast(default_value))))).*;
}

/// User-errors related to syntax issues
pub const SyntaxError = error{
    MaxTwoDashesAllowed,
};
/// User-errors related to passing parameters in
/// an incorrect way
pub const ParameterError = error{
    MissingArgument,
    InvalidOption,
    UnknownOption,
    UnknownFlag,
    UnknownArgument,
    TooManyArguments,
    IncorrectArgumentType,
    InvalidChoice,
    InvalidBooleanValue,
    DuplicatedOptionName,
    DuplicatedFlag,
    UnknownSubcommand,
    UnknownPalette,
    FileTooBig,
    InvalidJSON,
};

/// All the errors that the parser can emit
pub const CliError = SyntaxError || ParameterError;

// ShortFlag are passed with `-', LongFlag with '--',
const FlagType = enum {
    Argument,
    ShortFlag,
    LongFlag,
};

/// Formats the help hint for a set of choices given by enum fields
/// The choices are separated with '|'
pub fn formatEnumChoices(fields: []const Type.EnumField) []const u8 {
    var choices: []const u8 = "";
    inline for (fields) |field| {
        choices = if (choices.len == 0) field.name else choices ++ "|" ++ field.name;
    }
    return choices;
}

/// Formats the help hint for a set of choices given by union fields
/// The choices are separated with '|'
pub fn formatUnionChoices(fields: []const Type.UnionField) []const u8 {
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
        .bool => "flag",
        .int => "integer",
        .float => "float",
        .@"enum" => |choices| formatEnumChoices(choices.fields),
        .@"union" => |choices| "(subcommand) " ++ formatUnionChoices(choices.fields),
        .optional => |opt| "(Optional) " ++ getTypeName(opt.child),
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
        .int, .float => "{d}",
        // .Enum => |choices| formatChoices(choices.fields), //TODO fix
        .@"enum" => |e| {
            for (e.fields) |field| {
                if (@as(T, @enumFromInt(field.value)) == default) {
                    return field.name;
                }
                @compileError("Internal error: failed to find default for enum");
            }
        },
        .optional => {
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
    const default_name = formatDefaultValue(option_field.type, option_field.default_value_ptr.?);
    try std.testing.expectEqualStrings("Bob", default_name);
}

test "format default non-string values" {
    const Options = struct { age: i32 = 42, height: f32 = 1.77, is_employee: bool = false };
    // const options: Options = comptime .{};
    const fields = std.meta.fields(Options);

    const default_age = formatDefaultValue(fields[0].type, fields[0].default_value_ptr.?);
    const default_height = formatDefaultValue(fields[1].type, fields[1].default_value_ptr.?);
    const default_is_employee = formatDefaultValue(fields[2].type, fields[2].default_value_ptr.?);

    try std.testing.expectEqualStrings("42", default_age);
    try std.testing.expectEqualStrings("1.77", default_height);
    try std.testing.expectEqualStrings("false", default_is_employee);
}

/// Init all fields to their default value.
/// Optionals are forced to null
fn initDefaults(comptime T: type, container: *T) void {
    inline for (std.meta.fields(T)) |field| {
        switch (@typeInfo(field.type)) {
            .optional => @field(container, field.name) = null,
            else => {
                if (field.default_value_ptr) |ptr| {
                    const value_ptr = @as(*field.type, @ptrCast(@constCast(@alignCast(ptr))));
                    @field(container, field.name) = value_ptr.*;
                }
            },
        }
    }
}

/// Builds a map mapping each parameter name of a struct to a boolean  stating
/// whether the parameter is mandatory (=non-defaulted) or not
fn buildRequiredParamsMap(comptime Params: Struct) std.StaticStringMap(bool) {
    const KVType = struct { []const u8, bool };
    const kv_pairs = comptime blk: {
        var kv: [Params.fields.len]KVType = undefined;
        for (0.., Params.fields) |i, field| {
            kv[i] = .{ field.name, (field.default_value_ptr == null) };
        }
        break :blk kv;
    };

    return std.StaticStringMap(bool).initComptime(kv_pairs);
}

/// Rturns the number of required params in the passed struct
/// Useful for comptme logic that needs to extract a static size
/// required parameterd
fn getRequiredParamsCount(comptime Params: Struct) usize {
    var count: usize = 0;
    for (Params.fields) |field| {
        if (field.default_value_ptr == null) {
            count += 1;
        }
    }
    return count;
}

fn getRequiredParams(comptime Params: Struct) []const []const u8 {
    const results = comptime blk: {
        const len = getRequiredParamsCount(Params);
        var results: [len][]const u8 = undefined;
        var index: usize = 0;
        for (Params.fields) |field| {
            if (field.default_value_ptr == null) {
                results[index] = field.name;
                index += 1;
            }
        }
        break :blk results;
    };
    return &results;
}
test "get required params" {
    const TestStruct = struct { a: i32 = 0, b: f32, c: f32 = 0.0, d: i32 };
    const required_params = getRequiredParams(@typeInfo(TestStruct).@"struct");
    try std.testing.expectEqualStrings("b", required_params[0]);
    try std.testing.expectEqualStrings("d", required_params[1]);
    try std.testing.expectEqual(2, required_params.len);
}

test "mandatory params" {
    const TestStruct = struct { a: i32 = 0, b: f32, c: f32 = 0.0, d: i32 };
    const mandatory_params = buildRequiredParamsMap(@typeInfo(TestStruct).@"struct");
    try std.testing.expectEqual(false, mandatory_params.get("a").?);
    try std.testing.expectEqual(true, mandatory_params.get("b").?);
    try std.testing.expectEqual(false, mandatory_params.get("c").?);
    try std.testing.expectEqual(true, mandatory_params.get("d").?);
}

/// Container for error information
/// allows displaying an more detailed and contextualized error message
/// to the final user
pub const ParamErrPayload = struct {
    value_str: ?[]const u8 = null,
    field_name: ?[]const u8 = null,

    pub fn get_field_name(self: ParamErrPayload) []const u8 {
        return self.field_name orelse panic("Field name missing from context", .{});
    }

    pub fn get_value_str(self: ParamErrPayload) []const u8 {
        return self.value_str orelse panic("Value string missing from context", .{});
    }
};
/// Converts a string value to the type `T`
fn autoCast(comptime T: type, value_str: []const u8) CliError!T {
    if (T == []const u8 or T == ?[]const u8) {
        return value_str;
    }
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, value_str, 10) catch {
            return CliError.IncorrectArgumentType;
        },
        .float => std.fmt.parseFloat(T, value_str) catch {
            return CliError.IncorrectArgumentType;
        },
        .optional => |option| try autoCast(option.child, value_str),
        // note: for bool, having the flag in the first place means true
        .bool => |_| {
            if (std.mem.eql(u8, "true", value_str)) {
                return true;
            }
            if (std.mem.eql(u8, "false", value_str)) {
                return false;
            }
            return CliError.InvalidBooleanValue;
        },
        .@"enum" => |choices| {
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
        .@"struct" => |s| return s,
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

pub inline fn getOptionInternalInfo(opt_name: []const u8, options_info: []const OptionInternalInfo) ?OptionInternalInfo {
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
) [struct_fields.len]_KVType {
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
                @compileError("Duplicate flag found");
            }
            slice_index += 1;
            if (slice_index == field.name.len) {
                @compileError("Duplicate option name found");
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
) std.StaticStringMap([]const u8) {
    const kv_pairs = comptime _buildShortFlagMap(struct_fields, options_info);
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
    const short_flag_map = buildShortFlagMap(OptionsStruct.fields, &.{}, false);
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
) [option_fields.len]OptionInternalInfo {
    var out: [option_fields.len]OptionInternalInfo = undefined;
    const flag_map = buildShortFlagMap(option_fields, options_info, true);
    for (0.., option_fields) |i, field| {
        const default_value = field.default_value_ptr orelse @compileError(
            \\All options should have a default !
        );
        var internal_opt = OptionInternalInfo{
            .name = field.name,
            .default_value = formatDefaultValue(field.type, default_value),
        };
        if (getOptionInfo(field.name, options_info)) |info| {
            internal_opt.help = info.help;
            internal_opt.hidden = info.hidden;
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
    const options_info = comptime parseOptionInfo(OptionsStruct.fields, &.{});
    try std.testing.expectEqualStrings("42", options_info[0].default_value.?);
    try std.testing.expectEqualStrings("false", options_info[1].default_value.?);
    try std.testing.expectEqualStrings("3.14", options_info[2].default_value.?);
    try std.testing.expectEqualStrings("Hello", options_info[3].default_value.?);
}

pub fn buildOptionInfoMap(
    comptime option_fields: []const StructField,
    comptime options_info: []const OptionInfo,
) std.StaticStringMap(OptionInternalInfo) {
    const options_parsed_info = parseOptionInfo(option_fields, options_info);
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
    const options_info = comptime buildOptionInfoMap(OptionsStruct.fields, &.{});

    try std.testing.expectEqualStrings(options_info.get("abcde").?.short_name, "a");
}

/// The comptime context for the parser:
/// * Which arguments and options to parse
/// * The (optional) documentation for these
/// * The name of the client, etc.
const CliContext = struct {
    opts: ?type = null,
    args: ?type = null,
    opts_info: []const OptionInfo = &.{},
    args_info: []const ArgInfo = &.{},
    builtin_info: []const OptionInternalInfo = &builtin_doc,
    name: ?[]const u8 = null,
    headline: ?[]const u8 = null,
    welcome_msg: ?[]const u8 = null,
    show_builtin_help: bool = false,
};

const ParserType = *const fn (*anyopaque, arg_it: *ArgIterator, error_payload: ?*ParamErrPayload) CliError!void;

/// Compile-time checks on argument fields
/// Verifies that no more than one subcommand is defined
pub fn argSanityCheck(arg_fields: []const StructField) void {
    var subcmd_count: usize = 0;
    inline for (arg_fields) |arg| {
        switch (@typeInfo(arg.type)) {
            .@"union" => |u| {
                subcmd_count += 1;
                inline for (u.fields) |field| {
                    switch (@typeInfo(field.type)) {
                        .@"struct" => {},
                        else => @compileError("Subcommand option values should be CliParser(...) themselves"),
                    }
                    if (!@hasField(field.type, "args") or !@hasField(field.type, "options")) {
                        @compileError("Subcommand option values should be CliParser(...) themselves");
                    }
                }
            },
            else => {},
        }
    }
    if (subcmd_count > 1) {
        @compileError("Only one argument can be used a subcommand !\n");
    }
}

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

        /// Checking at comptime if argument struct is OK
        const flag_to_name_map = buildShortFlagMap(OptionSt.fields, ctx.opts_info, false);
        const name_to_flag_map = buildShortFlagMap(OptionSt.fields, ctx.opts_info, true);
        const options_info_map = buildOptionInfoMap(OptionSt.fields, ctx.opts_info);

        //
        const required_arg_count = getRequiredParamsCount(ArgSt);
        const required_option_count = getRequiredParamsCount(OptionSt);

        pub fn runSubparser(
            self: *Self,
            cmd_name: []const u8,
            cmd_value: []const u8,
            arg_it: anytype,
            error_payload: ?*ParamErrPayload,
        ) CliError!void {
            inline for (ArgSt.fields) |arg| {
                if (std.mem.eql(u8, cmd_name, arg.name)) {
                    const fields = switch (@typeInfo(arg.type)) {
                        .@"union" => |u| u.fields,
                        else => return,
                    };
                    inline for (fields) |f| {
                        if (std.mem.eql(u8, cmd_value, f.name)) {
                            @field(self.args, arg.name) = @unionInit(arg.type, f.name, undefined);
                            return try @field(@field(self.args, arg.name), f.name).parseInternal(
                                arg_it,
                                error_payload,
                                self.builtin.cli_name,
                            );
                        }
                    }
                    return CliError.UnknownSubcommand;
                }
            }
        }

        pub fn isSubcommand(cmd_name: []const u8) bool {
            inline for (ArgSt.fields) |arg| {
                if (std.mem.eql(u8, cmd_name, arg.name)) {
                    switch (@typeInfo(arg.type)) {
                        .@"union" => return true,
                        else => {},
                    }
                }
            }
            return false;
        }

        /// Checks if the given argument is a boolean flag
        fn isFlag(arg_name: []const u8) CliError!bool {
            inline for ([_]Struct{ OptionSt, ArgSt, BuiltinSt }) |type_st| {
                inline for (type_st.fields) |field| {
                    if (std.mem.eql(u8, field.name, arg_name)) {
                        return switch (@typeInfo(field.type)) {
                            .bool => true,
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
            if (ctx.opts) |_| {
                for (ctx.opts_info) |opt| {
                    if (!opt.hidden) {
                        return true;
                    }
                }
            }
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

        pub fn parse(arg_it: anytype, error_payload: ?*ParamErrPayload) CliError!Self {
            var params: Self = undefined;
            try params.parseInternal(arg_it, error_payload, null);
            if (params.builtin.use_file) |fpath| {
                // we have to save the cli_name so we have to reparse
                const cli_name = params.builtin.cli_name;
                var parsed = Self.loadFromJsonFile(fpath, std.heap.page_allocator) catch {
                    return CliError.InvalidJSON;
                };
                parsed.builtin.cli_name = parsed.builtin.cli_name orelse cli_name;
                return parsed;
            }
            return params;
        }

        /// Loads the data from JSON file
        /// WARNING: the JSON data will not be freed
        /// Since this is specifcally meant for loading input variables
        /// and thus is a one-time thing for the lifetime of the process,
        /// it's fine to keep the file in memory forever- the OS will free this
        /// memory anyway on exit.
        /// If you want to manage this memory more closely, use `loadFromJsonè directly
        pub fn loadFromJsonFile(json_path: []const u8, allocator: Allocator) !Self {
            const file = try std.fs.cwd().openFile(json_path, .{});
            const reader = file.reader();
            const buffer = reader.readAllAlloc(allocator, 1 << 32) catch return CliError.FileTooBig;
            return Self.loadFromJson(buffer, allocator);
        }

        pub fn loadFromJson(json_string: []const u8, allocator: Allocator) !Self {
            const options: Self.OptionT = if (ctx.opts) |optT| blk: {
                const parsed = try std.json.parseFromSlice(
                    optT,
                    allocator,
                    json_string,
                    .{ .ignore_unknown_fields = true },
                );
                defer parsed.deinit();
                break :blk parsed.value;
            } else .{};
            const args: Self.ArgT = if (ctx.args) |argT| blk: {
                const parsed = try std.json.parseFromSlice(
                    argT,
                    allocator,
                    json_string,
                    .{ .ignore_unknown_fields = true },
                );
                defer parsed.deinit();
                break :blk parsed.value;
            } else .{};
            const parsed = (try std.json.parseFromSlice(
                BuiltinOptions,
                allocator,
                json_string,
                .{ .ignore_unknown_fields = true },
            ));
            defer parsed.deinit();
            const builtin = parsed.value;
            return .{ .options = options, .args = args, .builtin = builtin };
        }

        /// Parses the arguments and writes the results by mutation
        /// This should only be used as part of recursive procedures, stadnalone function is `parse`
        pub fn parseInternal(
            self: *Self,
            arg_it: anytype,
            error_payload: ?*ParamErrPayload,
            pname: ?[]const u8,
        ) CliError!void {
            initDefaults(OptionT, &(self.options));
            initDefaults(ArgT, &(self.args));
            initDefaults(BuiltinOptions, &(self.builtin));

            var arg_cnt: usize = 0;
            var passed_args: [ArgSt.fields.len][]const u8 = undefined;

            var is_option: bool = false;
            var flag_type: ?FlagType = null;
            var current_arg_name: []const u8 = "";
            var arg_idx: usize = 0;

            // If no explicit client name was passed,using process name
            if (pname) |name| {
                self.builtin.cli_name = ctx.name orelse name;
            } else {
                const process_name: []const u8 = arg_it.next() orelse panic("Process name is missing from arguments", .{});
                self.builtin.cli_name = ctx.name orelse getPathBasename(process_name);
            }
            var next_arg = arg_it.next();
            var consume = true;

            while (next_arg) |arg| {
                // consume will be set to false if we have an argument
                defer next_arg = if (consume) arg_it.next() else next_arg;

                if (flag_type) |_| {
                    consume = true;
                    defer flag_type = null;
                    // TODO: replace with simple boolean check, get rid of subparsers var
                    if (isSubcommand(current_arg_name)) {
                        try self.runSubparser(current_arg_name, arg, arg_it, error_payload);
                        continue;
                    }
                    if (arg_cnt > ArgSt.fields.len) {
                        return CliError.TooManyArguments;
                    }
                    // Note: below condition is monkey-patch for compiler that has special condition
                    // for array of size 0...
                    // it cannot find out that the if statement above statically makes that case impossible
                    if (ArgSt.fields.len > 0) {
                        passed_args[arg_cnt] = current_arg_name;
                    }
                    arg_cnt += 1;

                    self.parseArg(
                        current_arg_name,
                        arg,
                        is_option,
                    ) catch |e| {
                        if (error_payload) |p| {
                            p.value_str = arg;
                            p.field_name = current_arg_name;
                        }
                        return e;
                    };

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
                        current_arg_name = introspectArgName(arg_idx) catch |e| {
                            if (error_payload) |payload| {
                                payload.value_str = arg;
                            }
                            return e;
                        };
                        arg_idx += 1;
                        consume = false;
                    },
                    .ShortFlag => {
                        is_option = true;
                        current_arg_name = flag_to_name_map.get(arg[arg_name_start_idx..]) orelse {
                            if (error_payload) |p| {
                                p.value_str = arg;
                                p.field_name = arg[arg_name_start_idx..];
                            }
                            return CliError.UnknownFlag;
                        };
                        if (try isFlag(current_arg_name)) {
                            try self.parseFlag(current_arg_name);
                        }
                    },
                    .LongFlag => {
                        is_option = true;
                        current_arg_name = arg[arg_name_start_idx..];
                        const is_flag = isFlag(current_arg_name) catch |e| {
                            if (error_payload) |payload| {
                                payload.value_str = current_arg_name;
                                payload.field_name = current_arg_name;
                            }
                            switch (e) {
                                CliError.UnknownArgument => return CliError.UnknownOption,
                                else => return e,
                            }
                        };
                        if (is_flag) {
                            try self.parseFlag(current_arg_name);
                        }
                    },
                }
            }
            if (!self.builtin.help) {
                try checkMandatoryArgsPresence(&passed_args, error_payload);
            }
        }

        pub fn checkMandatoryArgsPresence(passed_args: [][]const u8, err_payload: ?*ParamErrPayload) CliError!void {
            const required_args = comptime getRequiredParams(ArgSt);
            inline for (required_args) |required| {
                var found = false;
                for (passed_args) |received| {
                    if (std.mem.eql(u8, required, received)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    if (err_payload) |payload| {
                        payload.field_name = required;
                        payload.value_str = required;
                    }
                    return CliError.MissingArgument;
                }
            }
        }

        pub fn emitWelcomeMessage(self: Self, writer: *const RichWriter) !void {
            if (self.builtin.cli_name) |name| {
                const headline = ctx.headline orelse default_welcome_message;
                writer.richPrint(headline, Style.Header1, .{name});
                writer.print("\n", .{});
                if (ctx.welcome_msg) |welcome_msg| {
                    writer.richPrint(welcome_msg ++ "\n\n", Style.Hint, .{});
                }
                return;
            }
            panic(
                \\No client name given and the parser has not run,
                \\ cannot format welcome message.
            , .{});
        }

        pub fn emitHelp(self: Self, writer: *const RichWriter) !void {
            writer.richPrint("===== Usage =====", .Header2, .{});
            // Showing typical usage
            writer.richPrint(">>> {s}", .Field, .{self.builtin.cli_name.?});
            inline for (std.meta.fields(ArgT)) |field| {
                writer.richPrint(" {{{s}}}  ", .Field, .{field.name});
            }
            writer.write("\n\n");

            // Formatting argument doc
            if (hasArguments()) {
                writer.richPrint(
                    "=== Arguments ===",
                    .Header2,
                    .{},
                );
                inline for (std.meta.fields(ArgT)) |field| {
                    writer.richPrint(
                        "{s}: {s}",
                        .Entry,
                        .{
                            field.name,
                            getTypeName(field.type),
                        },
                    );
                    if (getArgInfo(field.name, ctx.args_info)) |arg| {
                        if (arg.help) |help| {
                            writer.print("    {s}\n", .{help});
                        }
                    }
                }
                writer.write("\n");
            }

            const has_options = hasOptions() or ctx.show_builtin_help;
            if (has_options) {
                writer.richPrint(
                    "==== Options ====",
                    .Header2,
                    .{},
                );
                inline for (std.meta.fields(OptionT)) |field| {
                    const opt_internal_info = comptime options_info_map.get(field.name) orelse panic(
                        "Internal error: option {s} internal info has not been extracted properly",
                        .{field.name},
                    );
                    if (opt_internal_info.hidden) {
                        continue;
                    }
                    writer.richPrint(
                        "-{s}, --{s}: {s}",
                        .Field,
                        .{
                            opt_internal_info.short_name,
                            opt_internal_info.name,
                            getTypeName(field.type),
                        },
                    );
                    if (opt_internal_info.default_value) |default| {
                        writer.richPrint("    [default:{s}]", .Hint, .{default});
                    }
                    writer.write("\n");
                    if (getOptionInfo(field.name, ctx.opts_info)) |opt| {
                        if (opt.help) |help| {
                            writer.print("    {s}\n", .{help});
                        }
                    }
                }
                if (!ctx.show_builtin_help) return;
                inline for (std.meta.fields(BuiltinOptions)) |field| {
                    const opt_internal_info = getOptionInternalInfo(field.name, ctx.builtin_info).?;
                    writer.richPrint(
                        "--{s}: {s}",
                        .Field,
                        .{
                            opt_internal_info.name,
                            getTypeName(field.type),
                        },
                    );
                    writer.write("\n");
                    if (opt_internal_info.help) |help| {
                        writer.print("    {s}\n", .{help});
                    }
                }
            }
        }

        pub fn emitHelpRecursive(
            self: *Self,
            writer: *const RichWriter,
        ) CliError!bool {
            if (self.builtin.help) {
                try self.emitHelp(writer);
                return true;
            }
            inline for (ArgSt.fields) |arg| {
                switch (@typeInfo(arg.type)) {
                    .@"union" => {
                        switch (@field(self.args, arg.name)) {
                            inline else => |*parser| {
                                if (parser.builtin.help) {
                                    return try parser.emitHelpRecursive(writer);
                                }
                            },
                        }
                    },
                    else => continue,
                }
            }
            return false;
        }

        pub fn runStandaloneWithOptions(
            custom_arg_it: anytype,
            custom_writer: ?Writer,
        ) !?Self {
            comptime argSanityCheck(ArgSt.fields);
            var err_payload: ParamErrPayload = .{};
            const writer = custom_writer orelse std.io.getStdOut().writer();
            var params = Self.parse(custom_arg_it, &err_payload) catch |e| {
                displayError(e, err_payload, &writer);
                return null;
            };
            const user_palette = styling.palettes.get(params.builtin.palette) orelse {
                err_payload.field_name = "palette";
                err_payload.value_str = params.builtin.palette;
                displayError(CliError.UnknownPalette, err_payload, &writer);
                return null;
            };
            const rich_writer = RichWriter{ .writer = &writer, .palette = user_palette };
            std.debug.assert(params.builtin.cli_name != null);
            if (!params.builtin.quiet) {
                try params.emitWelcomeMessage(&rich_writer);
                if (try params.emitHelpRecursive(&rich_writer)) return null;
            }
            // handling logs
            if (params.builtin.log_level) |level| {
                global_level = level;
            }
            return params;
        }
        pub fn runStandalone() !?Self {
            var it = std.process.args();
            return runStandaloneWithOptions(&it, null);
        }

        /// Shows an error to the end user
        pub fn displayError(err: CliError, err_payload: ParamErrPayload, writer: *const Writer) void {
            const rich = RichWriter{ .writer = writer };
            switch (err) {
                ParameterError.MissingArgument => {
                    const param_name = err_payload.get_field_name();
                    rich.richPrint("Argument `{s}` is mandatory", .Error, .{param_name});
                },
                ParameterError.TooManyArguments => {
                    const param_name = err_payload.get_value_str();
                    rich.richPrint("Too many arguments: Did not expect {s}", .Error, .{param_name});
                },
                ParameterError.UnknownOption => {
                    const param_name = err_payload.get_field_name();
                    rich.richPrint("Option `{s}` is unknown", .Error, .{param_name});
                },
                ParameterError.UnknownFlag => {
                    const param_name = err_payload.get_field_name();
                    rich.richPrint("Flag `{s}` is unknown", .Error, .{param_name});
                },
                ParameterError.InvalidChoice => {
                    const param_name = err_payload.get_field_name();
                    const param_value = err_payload.get_value_str();
                    rich.richPrint("Choice `{s}` for `{s}` is invalid", .Error, .{ param_value, param_name });
                },
                ParameterError.UnknownPalette => {
                    const param_value = err_payload.get_value_str();
                    rich.richPrint("Unknown color palette `{s}`", .Error, .{param_value});
                },
                else => rich.richPrint("Usage error: {}", .Error, .{err}),
            }
        }
    };
}

/// Builtin options that are bundled autoamtically
/// with every CLI parser
pub const BuiltinOptions = struct {
    help: bool = false,
    cli_name: ?[]const u8 = null,
    log_level: ?std.log.Level = null,
    quiet: bool = false,
    palette: []const u8 = "default",
    use_file: ?[]const u8 = null,
};

const builtin_doc = [_]OptionInternalInfo{
    .{ .name = "help", .help = "Shows this menu" },
    .{ .name = "log_level", .help = "Sets the global log level for this application" },
    .{ .name = "quiet", .help = "Turns off the CLI output" },
    .{ .name = "palette", .help = "Which color palette to use, avaialble: clay|blueish|forest|christmas" },
    .{ .name = "use_file", .help = "A JSON file  from which to Load the arguments and option values " },
    .{ .name = "cli_name", .help = "The name of this tool ", .hidden = true },
};

// Basic test case that only uses options and does not require casting
test "parse with string parameters only" {
    const prompt = "testcli --arg_1 Argument1";
    var arguments = std.mem.splitSequence(u8, prompt, " ");
    const Options = struct {
        arg_1: ?[]const u8 = null,
    };
    const params = try CliParser(.{ .opts = Options }).parse(&arguments, null);
    try std.testing.expectEqualStrings("Argument1", params.options.arg_1.?);
}

test "parse with short flag parameters" {
    const prompt = "testcli -a Argument1";
    var arguments = std.mem.splitSequence(u8, prompt, " ");
    const Options = struct {
        arg_1: ?[]const u8 = null,
    };
    const params = try CliParser(.{
        .opts = Options,
    }).parse(&arguments, null);
    try std.testing.expectEqualStrings("Argument1", params.options.arg_1.?);
}

test "parse single argument" {
    const prompt = "testcli Argument1";
    var arguments = std.mem.splitSequence(u8, prompt, " ");
    const Args = struct {
        arg_1: ?[]const u8,
    };
    const params = try CliParser(.{ .args = Args }).parse(&arguments, null);
    try std.testing.expectEqualStrings("Argument1", params.args.arg_1.?);
}

test "parse many arguments" {
    const prompt = "testcli Argument1 Argument2";
    var arguments = std.mem.splitSequence(u8, prompt, " ");
    const Args = struct {
        arg_1: ?[]const u8 = null,
        arg_2: ?[]const u8 = null,
    };
    const params = try CliParser(.{ .args = Args }).parse(&arguments, null);
    try std.testing.expectEqualStrings("Argument1", params.args.arg_1.?);
    try std.testing.expectEqualStrings("Argument2", params.args.arg_2.?);
}

test "parse integer argument" {
    const prompt = "testcli 42";
    var arguments = std.mem.splitSequence(u8, prompt, " ");
    const Args = struct {
        arg_1: i32,
    };
    const params = try CliParser(.{ .args = Args }).parse(&arguments, null);
    try std.testing.expectEqual(42, params.args.arg_1);
}

test "parse float argument" {
    const prompt = "testcli 3.14";
    var arguments = std.mem.splitSequence(u8, prompt, " ");
    const Args = struct {
        arg_1: f64,
    };
    const params = try CliParser(.{ .args = Args }).parse(&arguments, null);
    try std.testing.expectEqual(3.14, params.args.arg_1);
}

test "parse boolean flag" {
    const prompt = "testcli --enable";
    var arguments = std.mem.splitSequence(u8, prompt, " ");
    const Options = struct {
        enable: bool = false,
    };
    const params = try CliParser(.{ .opts = Options }).parse(&arguments, null);
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
        var arguments = std.mem.splitSequence(u8, prompt, " ");
        const params = try CliParser(.{ .opts = Options }).parse(&arguments, null);
        try std.testing.expectEqual(expected[i], params.options.choice);
    }
}

test "parse choices invalid case" {
    const Choices = enum { choice_a, choice_b, choice_c };
    const Options = struct {
        choice: Choices = Choices.choice_a,
    };
    const prompt = "testcli --choice invalid";
    var arguments = std.mem.splitSequence(u8, prompt, " ");
    try std.testing.expectEqual(CliParser(.{ .opts = Options }).parse(&arguments, null), CliError.InvalidChoice);
}

test "parse help" {
    const prompt = "testcli --help";
    var arguments = std.mem.splitSequence(u8, prompt, " ");
    const params = try CliParser(.{}).parse(&arguments, null);
    try std.testing.expect(params.builtin.help);
}

test "parse from JSON" {
    const Options = struct {
        arg_1: ?[]const u8 = null,
    };
    const json_string =
        \\ {"arg_1": "dummy"}
    ;
    const params = try CliParser(.{
        .opts = Options,
    }).loadFromJson(json_string, std.testing.allocator);
    try std.testing.expectEqualStrings("dummy", params.options.arg_1.?);
}
