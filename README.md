# Zig easy CLI: build a CLI applications with a few lines of code
`zig-easy-cli` is a small utility library with zero dependency that lets you build your CLI applications with only a few lines of code.<br>
The main features are:
* Ease of use, you can get a working CLI app by defining a single struct
* Strong inference based on comptime programming, automatically builds the help menu
* Rich rendering using ANSI escape codes
* Customizable, you can build your own palettes, use arbitrary streams as output and not just stdout, and parametrize a fair bunch of rendering options.

# Usage
CLI applications typically supports two types of parameters: arguments (mandatory parameters that are passed in order), and options, typically identified by flags.
To get a basic working cli, you only need to define one struct for you arguments (they will be parsed in declaration order) and on struct for your options (with the defaults that you want). Then, simply create an `easycli.CliParser` with your two structs and call `runStandalone()` method to parse the arguments:
```zig
const std = @import("std");
const easycli = @import("parser.zig");

// for enums (like 'grade' below), the variants wil be translated to choices
// available to the user in the help menu
const DemoOptions = struct { surname: ?[]const u8, grade: enum { Employee, Boss } };
const DemoArgs = struct { name: ?[]const u8 };

pub fn main() !void {
    const ParserT = easycli.CliParser(DemoOptions, DemoArgs);
    // runStandalone returns null when the user calls --help
    // in that case you can simply return right away !
    const params = if (try ParserT.run_standalone()) |p| p else return;

    // If not querying help hint, you can now access you arguments !
    const name = if (params.arguments.name) |n| n else {
        std.debug.print("You need to pass your name !\n", .{});
        return;
    };

    if (params.options.surname) |surname| {
        std.debug.print("Hello {s} {s}!\n", .{ name, surname });
    } else {
        std.debug.print("Hello {s}!\n", .{name});
    }
}
```

This very basic version will already show the syntax, type and valid choices for your arguments and options. If you want to add documentation to your options or arguments, you can define some documentation structs as shown below:
```zig
/// Small demo code
const std = @import("std");
const easycli = @import("parser.zig");

const OptionInfo = easycli.OptionInfo;
const ArgInfo = easycli.ArgInfo;

const DemoOptions = struct { surname: ?[]const u8, grade: enum { Employee, Boss } };
const DemoArgs = struct { name: ?[]const u8 };

const options_doc = [_]OptionInfo{
    .{ .name = "surname", .help = "Your surname" },
};

const arg_doc = [_]ArgInfo{
    .{ .name = "name", .help = "Your name" },
};
pub fn main() !void {
    const ParserT = easycli.CliParser(DemoOptions, DemoArgs);
    const params = if (try ParserT.runStandalone(.{
        .options_info = &options_doc,
        .arg_info = &arg_doc,
    })) |p| p else return;
    const name = if (params.arguments.name) |n| n else {
        std.debug.print("You need to pass your name !\n", .{});
        return;
    };
    if (params.options.surname) |surname| {
        std.debug.print("Hello {s} {s}!\n", .{ name, surname });
    } else {
        std.debug.print("Hello {s}!\n", .{name});
    }
}

```

You can run it with:
```zig
zig build run -- 

>>> You need to pass your name !

zig build run -- John

>>> Hello John!

zig build run -- John --surname Doe

>>> Hello John Doe!

zig build run -- --help

*******************************
*                             *
*  Welcome to zig-easy-cli !  *
*                             *
*******************************


===== Usage =====
>>> zig-easy-cli {name}  

=== Arguments ===
name: (Optional) text
    Your name

==== Options ====
-s, --surname: (Optional) text
    Your surname
-g, --grade: Employee|Boss

```