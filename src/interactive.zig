//! Helpers and comptime logic around interactive prompts.
//!
const std = @import("std");

const InteractiveErrors = error{IncorrectChoice};

pub fn OptionsParser(T: type, default: ?T) type {
    const info = switch (@typeInfo(T)) {
        .@"enum" => |e| e,
        else => @compileError("OptionsParser only supports enum types"),
    };
    return struct {
        pub fn parse(response: []const u8) InteractiveErrors!T {
            if (response.len == 0) {
                return default orelse InteractiveErrors.IncorrectChoice;
            }
            inline for (0.., info.field_names) |i, name| {
                if (std.mem.eql(u8, name, response)) {
                    return @enumFromInt(info.field_values[i]);
                }
            }
            return InteractiveErrors.IncorrectChoice;
        }

        // '/' separated choices in () + default in brackets if any
        /// formats the response ("(yes/no) [yes]")
        pub fn getHint() []const u8 {
            return comptime blk: {
                var hint: []const u8 = "(";
                for (0.., info.field_names) |i, name| {
                    hint = hint ++ (if (i == 0) name else "/" ++ name);
                }
                hint = hint ++ ")";
                if (default) |d| {
                    hint = hint ++ " [" ++ @tagName(d) ++ "]";
                }
                break :blk hint;
            };
        }
    };
}

pub const YesNo = enum { yes, no };

test "parse valid choice" {
    const Parser = OptionsParser(YesNo, null);
    try std.testing.expectEqual(YesNo.yes, try Parser.parse("yes"));
    try std.testing.expectEqual(YesNo.no, try Parser.parse("no"));
}

test "parse invalid choice" {
    const Parser = OptionsParser(YesNo, null);
    try std.testing.expectError(InteractiveErrors.IncorrectChoice, Parser.parse("maybe"));
}

test "parse empty response falls back to default" {
    const Parser = OptionsParser(YesNo, .yes);
    try std.testing.expectEqual(YesNo.yes, try Parser.parse(""));
}

test "parse empty response without default is an error" {
    const Parser = OptionsParser(YesNo, null);
    try std.testing.expectError(InteractiveErrors.IncorrectChoice, Parser.parse(""));
}

test "get hint without default" {
    const Parser = OptionsParser(YesNo, null);
    try std.testing.expectEqualStrings("(yes/no)", Parser.getHint());
}

test "get hint with default" {
    const Parser = OptionsParser(YesNo, .yes);
    try std.testing.expectEqualStrings("(yes/no) [yes]", Parser.getHint());
}

const Choice = enum { A, B, C, D };

test "parse valid choice among more than two options" {
    const Parser = OptionsParser(Choice, null);
    try std.testing.expectEqual(Choice.A, try Parser.parse("A"));
    try std.testing.expectEqual(Choice.B, try Parser.parse("B"));
    try std.testing.expectEqual(Choice.C, try Parser.parse("C"));
    try std.testing.expectEqual(Choice.D, try Parser.parse("D"));
}

test "parse invalid choice among more than two options" {
    const Parser = OptionsParser(Choice, null);
    try std.testing.expectError(InteractiveErrors.IncorrectChoice, Parser.parse("E"));
}

test "parse empty response falls back to a non-first default" {
    const Parser = OptionsParser(Choice, .C);
    try std.testing.expectEqual(Choice.C, try Parser.parse(""));
}

test "get hint for more than two options" {
    const Parser = OptionsParser(Choice, null);
    try std.testing.expectEqualStrings("(A/B/C/D)", Parser.getHint());
}

test "get hint for more than two options with a non-first default" {
    const Parser = OptionsParser(Choice, .C);
    try std.testing.expectEqualStrings("(A/B/C/D) [C]", Parser.getHint());
}
