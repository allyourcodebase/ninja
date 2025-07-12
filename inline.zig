pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
    const all_args = try std.process.argsAlloc(arena);
    if (all_args.len <= 1) {
        try std.io.getStdErr().writer().writeAll("Usage: inline VARNAME IN_FILE OUT_FILE\n");
        std.process.exit(0xff);
    }
    const args = all_args[1..];
    if (args.len != 3) errExit("expected 3 cmdline args but got {}", .{args.len});
    const varname = args[0];
    const in_file_path = args[1];
    const out_file_path = args[2];

    const content = blk: {
        var file = std.fs.cwd().openFile(in_file_path, .{}) catch |e| errExit(
            "failed to open '{s}' with {s}",
            .{ in_file_path, @errorName(e) },
        );
        defer file.close();
        break :blk try file.readToEndAlloc(arena, std.math.maxInt(usize));
    };

    var out_file = try std.fs.cwd().createFile(out_file_path, .{});
    defer out_file.close();
    var bw = std.io.bufferedWriter(out_file.writer());
    const writer = bw.writer();

    try writer.print("const char {s}[] =\n\"", .{varname});
    for (content, 0..) |byte, i| {
        if (i > 0 and (i % 16) == 0) {
            try writer.writeAll("\"\n\"");
        }
        try writer.print("\\x{x:0>2}", .{byte});
    }
    try writer.writeAll("\";\n");
    try bw.flush();
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const std = @import("std");
