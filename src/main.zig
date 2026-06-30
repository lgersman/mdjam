const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const App = @import("app.zig").App;

var tty_buf: [4096]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = init.minimal.args;

    var it = std.process.Args.Iterator.init(args);
    _ = it.next(); // skip argv[0]

    var file_path: ?[]const u8 = null;
    var stdin_mode = false;
    var no_auto = false;
    var no_watch = false;
    var verbose = false;

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--stdin")) {
            stdin_mode = true;
        } else if (std.mem.eql(u8, arg, "--no-auto")) {
            no_auto = true;
        } else if (std.mem.eql(u8, arg, "--no-watch")) {
            no_watch = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, help_text);
            return;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            try std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, "mdjam 0.1.0-zig\n");
            return;
        } else if (std.mem.eql(u8, arg, "--theme") or std.mem.eql(u8, arg, "--delegate")) {
            _ = it.next(); // consume value
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            file_path = arg;
        }
    }

    if (file_path == null and !stdin_mode) {
        try std.Io.File.writeStreamingAll(std.Io.File.stderr(), io, "Usage: mdjam [options] <file.md>\n       mdjam --help\n");
        return error.MissingArgument;
    }

    const path = file_path orelse "";

    const app = try App.create(gpa, io, init.environ_map, path, .{
        .stdin_mode = stdin_mode,
        .no_auto = no_auto,
        .no_watch = no_watch,
        .verbose = verbose,
    });
    defer app.destroy();

    var vxfw_app = try vxfw.App.init(io, gpa, init.environ_map, &tty_buf);
    defer vxfw_app.deinit();

    // Wire up suspend/resume callbacks for interactive blocks
    app.setVxfwApp(&vxfw_app);

    try vxfw_app.run(app.widget(), .{});
}

const help_text =
    \\mdjam — terminal markdown viewer with executable code blocks
    \\
    \\Usage:
    \\  mdjam [options] <file.md>
    \\  mdjam [options] --stdin
    \\
    \\Options:
    \\  --stdin            Read markdown from stdin
    \\  --no-auto          Suppress auto-execution of auto:true blocks
    \\  --no-watch         Disable file watch/reload on change
    \\  --theme <name>     dark | light | dracula | tokyo-night  [default: dark]
    \\  --verbose          Show frontmatter as YAML header
    \\  --delegate         Forward focused block output on exit
    \\  -h, --help         Show this help
    \\  -v, --version      Print version
    \\
;
