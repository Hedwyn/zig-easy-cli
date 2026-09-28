/// Demonstrates how to set logging level with easy-cli
const std = @import("std");
const Level = std.log.Level;
const easycli = @import("parser");
const OptionInfo = easycli.OptionInfo;
const ArgInfo = easycli.ArgInfo;

const LogDemoOptions = struct {
    times: usize = 1,
};
const LogDemoArgs = struct { message: []const u8 };

const options_doc = [_]OptionInfo{
    .{ .name = "times", .help = "How many times to repeat the log" },
};

const arg_doc = [_]ArgInfo{
    .{ .name = "message", .help = "Message to log" },
};

pub const std_options = std.Options{
    // Set the log level to info
    .log_level = .info,

    // Define logFn to override the std implementation
    .logFn = easycli.logHandler,
};

pub const ParserT = easycli.CliParser(.{
    .opts = LogDemoOptions,
    .args = LogDemoArgs,
    .opts_info = &options_doc,
    .args_info = &arg_doc,
});

pub fn main(init: std.process.Init) !void {
    const params = if (try ParserT.runStandalone(init)) |p| p else return;

    // Some dummy log records...
    std.log.debug("If you see this, debug level is set !", .{});
    std.log.info("If you see this, at least info level is set !", .{});
    std.log.warn("If you see this, at least warning level is set !", .{});
    std.log.err("If you see this, at least error level is set !", .{});

    // In a programmatic way
    const level_info = @typeInfo(Level).@"enum";
    inline for (0.., level_info.field_names) |i_field, field_name| {
        const level: Level = @enumFromInt(level_info.field_values[i_field]);

        for (0..params.options.times) |i| {
            std.options.logFn(level, .default, "[{s}] Saying `{s}`, attempt {d}", .{
                field_name,
                params.args.message,
                i,
            });
        }
    }
}
