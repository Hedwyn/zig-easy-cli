const std = @import("std");

const examples = &.{
    "whoami",
    "subcmd",
    "logs",
    "minimal",
    "secret",
};
// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "zig-easy-cli",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    const parser_module = b.addModule("parser", .{ .root_source_file = b.path("src/parser.zig") });
    const styling_module = b.addModule("styling", .{ .root_source_file = b.path("src/styling.zig") });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    const examples_step = b.step("examples", "Run examples");

    inline for (examples) |example_name| {
        const example = b.addExecutable(.{
            .name = example_name,
            .root_source_file = b.path("examples/" ++ example_name ++ ".zig"),
            .target = target,
            .optimize = optimize,
        });
        example.root_module.addImport("parser", parser_module);
        example.root_module.addImport("styling", styling_module);
        const run_example_step = b.step(example_name, "Run " ++ example_name);
        const example_run = b.addRunArtifact(example);
        run_example_step.dependOn(&example_run.step);
        if (b.args) |args| {
            example_run.addArgs(args);
        }
    }

    b.default_step.dependOn(examples_step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/parser.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
