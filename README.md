# Usage
This project is under construction, currently only supports options with string values passed with `--` style flags.

See the small demo in `main.zig`:
```zig
/// Small demo code
const std = @import("std");
const easycli = @import("root.zig");

const DemoParams = struct { name: ?[]const u8 };

pub fn main() !void {
    var args_it = std.process.args();
    const allocator = std.heap.page_allocator;
    const ctx = easycli.CliContext{};
    const parser = easycli.CliParser(DemoParams, struct {}){ .context = ctx, .allocator = allocator };
    const params = try parser.parse(&args_it);
    if (params.options.name) |name| {
        std.debug.print("Hello {s} !\n", .{name});
    } else {
        std.debug.print("You need to pass the --name flag !\n", .{});
    }
}
```

You can run it with:
```zig
zig build run -- --name Bob

Hello Bob !
```