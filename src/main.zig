/// Small demo code
const std = @import("std");
const easycli = @import("root.zig");

const DemoParams = struct { name: ?[]const u8 };

pub fn main() !void {
    var args_it = std.process.args();
    const allocator = std.heap.page_allocator;
    const ctx = easycli.CliContext{};
    const parser = easycli.CliParser(DemoParams){ .context = ctx, .allocator = allocator };
    const params = try parser.parse(&args_it);
    if (params.name) |name| {
        std.debug.print("Hello {s} !\n", .{name});
    } else {
        std.debug.print("You need to pass the --name flag !\n", .{});
    }
}
