# Zig easy CLI: build a CLI applications with a few lines of code
`zig-easy-cli` is a small utility library with zero dependency that lets you build your CLI applications with only a few lines of code.<br>
The main features are:
* Ease of use, you can get a working CLI app by defining a single struct
* Strong inference based on comptime programming, automatically builds the help menu
* Rich rendering using ANSI escape codes
* Customizable, you can build your own palettes, use arbitrary streams as output and not just stdout, and parametrize a fair bunch of rendering options.

# Requirements
This is tested for zig 0.13.

# Examples
You can build the examples with `zig build examples`. Examples can be found in `examples` folder. They all have a standalone command to run them, e.g, to build and run `whoami` example just call `zig build examples whoami -- --help` (*Note: the flags you want to pass to the command should go after `--` separator). The examples are shown below (note: in your terminal they will be rendeez with colors andother embellishments)

## minimal
A stripped down exmaple to show how little information is required to build a working CLI.

```shell
zig build examples minimal -- --help

**************************
*                        *
*  Welcome to minimal !  *
*                        *
**************************


===== Usage =====
>>> minimal {name}

=== Arguments ===
name: (Optional) text
```

## whoami
An example of typical usage of this package.
```shell
zig build examples whoami -- --help


*************************
*                       *
*  Welcome to whoami !  *
*                       *
*************************


Pass your identity, the program will echo it for you.

===== Usage =====
>>> whoami {name}

=== Arguments ===
name: (Optional) text
    Your name

==== Options ====
-s, --surname: (Optional) text    [default:none]
    Your surname
-g, --grade: Employee|Boss    [default:Employee]
-se, --secret: (Optional) text    [default:none]
```

## subcmd

Demonstrates how to defines subcommands with subparsers.

```shell
zig build examples subcmd -- --help

*************************
*                       *
*  Welcome to subcmd !  *
*                       *
*************************


===== Usage =====
>>> subcmd {subcmd}

=== Arguments ===
subcmd: (subcommand) whoami
```

## secret
Demonstrates hidden options:

```shell
zig build examples secret -- --help

*************************
*                       *
*  Welcome to secret !  *
*                       *
*************************


A mysterious program... what does it do ?

===== Usage =====
>>> secret {username}

=== Arguments ===
username: (Optional) text
```

# Usage
CLI applications typically supports two types of parameters: arguments (mandatory parameters that are passed in order), and options, typically identified by flags.
To get a basic working cli, you only need to define one struct for you arguments (they will be parsed in declaration order) and on struct for your options (with the defaults that you want). Then, simply create an `easycli.CliParser` with your two structs and call `runStandalone()` method to parse the arguments:
```zig
/// Small demo code
const std = @import("std");
const easycli = @import("parser.zig");

const DemoOptions = struct {
    surname: ?[]const u8 = null,
    grade: enum { Employee, Boss } = .Employee,
};
const DemoArgs = struct { name: ?[]const u8 };

pub fn main() !void {
    const ParserT = easycli.CliParser(.{
        .opts = DemoOptions,
        .args = DemoArgs,
    });
    const params = if (try ParserT.runStandalone()) |p| p else return;
    const name = if (params.args.name) |n| n else {
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

const DemoOptions = struct {
    surname: ?[]const u8 = null,
    grade: enum { Employee, Boss } = .Employee,
};
const DemoArgs = struct { name: ?[]const u8 };

const options_doc = [_]OptionInfo{
    .{ .name = "surname", .help = "Your surname" },
};

const arg_doc = [_]ArgInfo{
    .{ .name = "name", .help = "Your name" },
};
pub fn main() !void {
    const ParserT = easycli.CliParser(.{
        .opts = DemoOptions,
        .args = DemoArgs,
        .opts_info = &options_doc,
        .args_info = &arg_doc,
    });
    const params = if (try ParserT.runStandalone()) |p| p else return;
    const name = if (params.args.name) |n| n else {
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

You can run it as follows:
```zig
zig build whoami -- 

*******************************
*                             *
*  Welcome to zig-easy-cli !  *
*                             *
*******************************


You need to pass your name !
```

```
zig build whoami -- John

>>> Hello John!

zig build whoami -- John --surname Doe

>>> Hello John Doe!
```

Help menu will be generated automatically by zig-easy-cli and can be summoned with `--help`:
```
zig build whoami -- --help

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
-s, --surname: (Optional) text    [default:none]
    Your surname
-g, --grade: Employee|Boss    [default:Employee]

```

# Builtin options
The parser support some builtin flags that are always available regardless of your custom options or arguments:
* `--help`: Shows the help menu as demonstrated above
* `--log_level`: Sets the log level for your application. Valid values are **debug**, **info**, **warn**, **err**. **You need to set the asycli log handler as your main log handler for this to be enabled**:

```zig
// Add this to your main
pub const std_options = .{
    // Set your default log level here
    .log_level = .info,

    // Define logFn to override the std implementation
    .logFn = easycli.logHandler,
};
```

# Subcommands
This tool also supports subcommands, with their individual parsers. An example is available in `examples/subcmd.zig`. Subcommands should be defined as tagged unions, each variant type being a `CliParser` itself. For example:

```zig
const WhoamiOptions = struct {
    surname: ?[]const u8 = null,
    grade: enum { Employee, Boss } = .Employee,
    secret: ?[]const u8 = null,
};
const WhoamiArg = struct { name: ?[]const u8 };

const Subcommands = union(enum) {
    whoami: easycli.CliParser(
        .{
            .opts = WhoamiOptions,
            .args = WhoamiArg,
            .opts_info = &options_doc,
            .args_info = &arg_doc,
        },
    ),
};

const MainArg = struct {
    subcmd: Subcommands,
};
```

Note that subcommands is the **only** valid use of Tagged Unions as field for the parser. Using anything that's not a `CliParser(...)` type as variant type will raise a compile-time error.

# Comparison with existing projects for CLI tools
There are a few other CLI libraries for zig out there.

The core idea of `zig-easy-cli` is to isolate the CLI parts so they do not leak (or as little as possible) on the core logic of your library or application. What that means is that the job of the CLi layer is to provide an easy and convenient way of injecting data from the outside into the core logic: thus, the interface between the CLI and the inner logic should simple structs of data. There are two central core ideas in `zig-easy-cli`:
* **Strict separation of CLI logic**: `zig-easy-cli` is though as as simple hook to inject data into your core logic without requiring this inner logic to know about your particular CLI tool. As you can see in the examples above, ·`zig-easy-cli` works primarily from a struct for the arguments and a struct for the options, with no added fluff to them, which means they can be passed directly to inner logic without any leaky pure-CLI stuff. The pure-CLI information is passed in isolated structs (these `options_doc` and `args_doc` optional fields that you can pass in your context) and are seperated from the data model. 
* **Static-memory and comptime- logic**: Another key point is that `zig-easy-cli` is 90%+ pure comptime-logic, and is actually designed to work statically, without using the heap. You can see in the examples above that there isn't an allocator in sight. The struct holding oyur arguments and options do not need to live on the stack. Obviously the part reading from stdout itself uses an allocator internally, but once the parsing is done there's nothing left on the heap and everything exist statically.

This being clarified, you can find below some of the main differences between this project and them to make your choice depending on your needs. Keep in mind that `zig-easy-cli` is still under construction and not quite as stable as these other projects, but it does take a different approach that might in some case be better suited to your needs.</br>

## zig-clap
[zig-clap](https://github.com/Hejsil/zig-clap) takes the complete opposite approach when it comes to the dependency model and the parsing of arguments. `zig-easy-cli` uses the data model as source of truth and builds a help menu from it; `zig-clap` on the other hand, uses the help menu as source of truth and builds the data model from it. The data that the parser spits out is organized in a similar way, but it has to be dynamically allocated.

## zig-cli
[zig-cli](https://github.com/sam701/zig-cli) uses structs as source of truth similar to the `options_doc` and `args_doc` in this project, but instead of building statically the data it uses a mutation model where the CLI structs allows passing reference to where the data should be written (by mutation). It also uses primarily dynamic allocation. 