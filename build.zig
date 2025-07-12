pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const upstream = b.dependency("upstream", .{});
    const upstream_root = upstream.path(".");

    const inline_exe = b.addExecutable(.{
        .name = "inline",
        .root_module = b.createModule(.{
            .root_source_file = b.path("inline.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const browse_py_h = blk: {
        const run = b.addRunArtifact(inline_exe);
        run.addArg("kBrowsePy");
        run.addFileArg(upstream.path("src/browse.py"));
        break :blk run.addOutputFileArg("build/browse_py.h");
    };
    const exe = b.addExecutable(.{
        .name = "ninja",
        .target = target,
        .optimize = optimize,
    });
    switch (target.result.os.tag) {
        .windows => {},
        else => {
            const python = b.option([]const u8, "python", "Python interpreter to use for the browse tool") orelse "python";
            exe.root_module.addCMacro("NINJA_PYTHON", b.fmt("\"{s}\"", .{python}));
            exe.addIncludePath(browse_py_h.dirname().dirname());
        },
    }
    exe.addCSourceFiles(.{
        .root = upstream_root,
        .files = switch (target.result.os.tag) {
            .windows => &(src_common ++ src_win32),
            else => &(src_common ++ src_posix),
        },
    });
    exe.linkLibCpp();
    b.installArtifact(exe);
}

const src_common = [_][]const u8{
    "src/build.cc",
    "src/build_log.cc",
    "src/clean.cc",
    "src/clparser.cc",
    "src/debug_flags.cc",
    "src/depfile_parser.cc",
    "src/deps_log.cc",
    "src/disk_interface.cc",
    "src/dyndep.cc",
    "src/dyndep_parser.cc",
    "src/edit_distance.cc",
    "src/elide_middle.cc",
    "src/eval_env.cc",
    "src/graph.cc",
    "src/graphviz.cc",
    "src/jobserver.cc",
    "src/json.cc",
    "src/lexer.cc",
    "src/line_printer.cc",
    "src/manifest_parser.cc",
    "src/metrics.cc",
    "src/missing_deps.cc",
    "src/ninja.cc",
    "src/parser.cc",
    "src/real_command_runner.cc",
    "src/state.cc",
    "src/status_printer.cc",
    "src/string_piece_util.cc",
    "src/util.cc",
    "src/version.cc",
};
const src_win32 = [_][]const u8{
    "src/getopt.c",
    "src/includes_normalize-win32.cc",
    "src/jobserver-win32.cc",
    "src/minidump-win32.cc",
    "src/msvc_helper-win32.cc",
    "src/msvc_helper_main-win32.cc",
    "src/subprocess-win32.cc",
};
const src_posix = [_][]const u8{
    "src/browse.cc",
    "src/jobserver-posix.cc",
    "src/subprocess-posix.cc",
};

const std = @import("std");
