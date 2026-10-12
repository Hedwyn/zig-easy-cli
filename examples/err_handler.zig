//! Custom error handler: instead of the default error display, the parser
//! calls `onError` and exits with the code it returns.
//!
//! The number given as argument selects which error to raise:
//!   ./zig-out/bin/err_handler 1   # unknown option
//!   ./zig-out/bin/err_handler 2   # invalid choice
//!   ./zig-out/bin/err_handler 3   # too many arguments
//!   ./zig-out/bin/err_handler 4   # any other usage error
//! Parsing errors (e.g. `err_handler abc`, or no argument) go through the same handler.
const std = @import("std");
const easycli = @import("parser");
const styling = @import("styling");

const CliError = easycli.CliError;
const RichWriter = styling.RichWriter;

/// Shows something different depending on the kind of error,
/// and returns a dedicated exit code
fn onError(err: CliError, rich: RichWriter) u8 {
    switch (err) {
        CliError.UnknownOption => {
            rich.richPrint("[unknown option] ", .Error, .{});
            rich.richPrint("Try `--help` to list the available options\n", .Hint, .{});
            return 2;
        },
        CliError.InvalidChoice => {
            rich.richPrint("[invalid choice] ", .Error, .{});
            rich.richPrint("The value is not one of the allowed choices\n", .Hint, .{});
            return 3;
        },
        CliError.TooManyArguments => {
            rich.richPrint("[too many arguments] ", .Error, .{});
            rich.print("Only a single number is expected\n", .{});
            return 4;
        },
        CliError.MissingArgument, CliError.IncorrectArgumentType => {
            rich.richPrint("[bad number] ", .Error, .{});
            rich.richPrint("Please pass an integer, e.g. `err_handler 2`\n", .Hint, .{});
            return 5;
        },
        else => {
            rich.richPrint("[error] ", .Error, .{});
            rich.print("{}\n", .{err});
            return 1;
        },
    }
}

const Parser = easycli.CliParser(.{
    .args = struct { number: i32 },
    .err_handler = onError,
});

pub fn main(init: std.process.Init) !void {
    const params = if (try Parser.runStandalone(init)) |p| p else return;

    // Raising the errors by hand, the same way the parser would on bad input
    const stdout = std.Io.File.stdout();
    var file_writer = stdout.writer(init.io, &.{});
    const err: CliError = switch (params.args.number) {
        1 => CliError.UnknownOption,
        2 => CliError.InvalidChoice,
        3 => CliError.TooManyArguments,
        else => CliError.InvalidJSON,
    };
    Parser.handleError(err, .{}, &file_writer.interface);
}
