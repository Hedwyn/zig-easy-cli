/// Shows a progress bar on stdout, with log lines printed while it is active
const std = @import("std");
const styling = @import("styling");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buf);
    const out = &file_writer.interface;
    const interactive = try std.Io.File.stdout().isTty(io);

    const rich: styling.RichWriter = .{
        .writer = out,
        .palette = styling.palettes.get("clay").?,
    };

    const total = 200;
    var bar = rich.progressBar(.{
        .total = total,
        .label = "Downloading",
        .width = 40,
        .interactive = interactive,
    });
    try bar.start();
    for (0..total) |i| {
        try io.sleep(.fromMilliseconds(15), .awake);
        try bar.advance(1);
        // Output managed by the bar: printed above it, the bar stays at the bottom
        if (i % 50 == 49) try bar.log("checkpoint: {d} items done", .{i + 1});
    }
    try bar.finish();

    // A second bar, with the default colors and no counters
    var bar2 = styling.ProgressBar.init(out, .{
        .total = 100,
        .width = 30,
        .show_count = false,
        .interactive = interactive,
    });
    try bar2.start();
    for (0..100) |_| {
        try io.sleep(.fromMilliseconds(10), .awake);
        try bar2.advance(1);
    }
    try bar2.finish();
}
