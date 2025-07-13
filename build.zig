pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("upstream", .{});
    const inline_exe = b.addExecutable(.{
        .name = "inline",
        .root_module = b.createModule(.{
            .root_source_file = b.path("inline.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const config: NinjaConfig = .{
        .browse_py_h = blk: {
            const run = b.addRunArtifact(inline_exe);
            run.addArg("kBrowsePy");
            run.addFileArg(upstream.path("src/browse.py"));
            break :blk run.addOutputFileArg("build/browse_py.h");
        },
        .python = b.option([]const u8, "python", "Python interpreter to use for the browse tool") orelse "python",
    };

    {
        const exe = addNinja(b, target, optimize, config);
        b.installArtifact(exe);
    }

    const zip_dep = b.dependency("zip", .{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const host_zip_exe = zip_dep.artifact("zip");

    {
        const src = "pub fn main() !void { try @import(\"std\").io.getStdOut().writer().writeAll(\"version=" ++ zon.version ++ "\\n\"); }";
        const exe = b.addExecutable(.{
            .name = "version",
            .root_module = b.createModule(.{
                .root_source_file = b.addWriteFiles().add("version.zig", src),
                .target = b.graph.host,
            }),
        });
        b.step("version", "").dependOn(&b.addRunArtifact(exe).step);
    }

    const ci_step = b.step("ci", "The build/test step to run on the CI");
    ci_step.dependOn(b.getInstallStep());
    try ci(b, config, ci_step, host_zip_exe);
}

const zon: struct {
    name: @TypeOf(.enum_literal),
    fingerprint: u64,
    version: []const u8,
    minimum_zig_version: []const u8,
    dependencies: struct {
        upstream: Dependency,
        zip: Dependency,
    },
    paths: []const []const u8,

    const Dependency = struct {
        url: []const u8,
        hash: []const u8,
    };
} = @import("build.zig.zon");

const NinjaConfig = struct {
    browse_py_h: std.Build.LazyPath,
    python: []const u8,
};

fn addNinja(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    config: NinjaConfig,
) *std.Build.Step.Compile {
    const upstream = b.dependency("upstream", .{});
    const exe = b.addExecutable(.{
        .name = "ninja",
        .target = target,
        .optimize = optimize,
    });
    switch (target.result.os.tag) {
        .windows => {},
        else => {
            exe.root_module.addCMacro("NINJA_PYTHON", b.fmt("\"{s}\"", .{config.python}));
            exe.addIncludePath(config.browse_py_h.dirname().dirname());
        },
    }
    exe.addCSourceFiles(.{
        .root = upstream.path("."),
        .files = switch (target.result.os.tag) {
            .windows => &(src_common ++ src_win32),
            else => &(src_common ++ src_posix),
        },
    });
    exe.linkLibCpp();
    return exe;
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

fn ci(
    b: *std.Build,
    config: NinjaConfig,
    ci_step: *std.Build.Step,
    host_zip_exe: *std.Build.Step.Compile,
) !void {
    const ci_targets = [_][]const u8{
        "x86_64-windows",
        "aarch64-windows",
        "x86-windows",

        "x86_64-macos",
        "aarch64-macos",

        "x86_64-linux",
        "aarch64-linux",
        "arm-linux",
        "riscv64-linux",
        "powerpc64le-linux",
        "x86-linux",
        "s390x-linux",
    };

    const make_archive_step = b.step("archive", "Create CI archives");
    ci_step.dependOn(make_archive_step);

    for (ci_targets) |ci_target_str| {
        const target = b.resolveTargetQuery(try std.Target.Query.parse(
            .{ .arch_os_abi = ci_target_str },
        ));
        const optimize: std.builtin.OptimizeMode = .ReleaseFast;
        const target_dest_dir: std.Build.InstallDir = .{ .custom = ci_target_str };
        const install = b.step(b.fmt("install-{s}", .{ci_target_str}), "");
        ci_step.dependOn(install);
        const exe = addNinja(b, target, optimize, config);
        install.dependOn(
            &b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = target_dest_dir } }).step,
        );
        if (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) {
            make_archive_step.dependOn(makeCiArchiveStep(
                b,
                ci_target_str,
                target.result,
                target_dest_dir,
                install,
                host_zip_exe,
            ));
        }
    }
}

fn makeCiArchiveStep(
    b: *std.Build,
    ci_target_str: []const u8,
    target: std.Target,
    target_install_dir: std.Build.InstallDir,
    install: *std.Build.Step,
    host_zip_exe: *std.Build.Step.Compile,
) *std.Build.Step {
    const install_path = b.getInstallPath(.prefix, ".");

    if (target.os.tag == .windows) {
        const out_zip_file = b.pathJoin(&.{
            install_path,
            b.fmt("ninja-{s}.zip", .{ci_target_str}),
        });
        const zip = b.addRunArtifact(host_zip_exe);
        zip.addArg(out_zip_file);
        zip.addArg("ninja.exe");
        zip.addArg("ninja.pdb");
        zip.cwd = .{ .cwd_relative = b.getInstallPath(
            target_install_dir,
            ".",
        ) };
        zip.step.dependOn(install);
        return &zip.step;
    }

    const targz = b.pathJoin(&.{
        install_path,
        b.fmt("ninja-{s}.tar.gz", .{ci_target_str}),
    });
    const tar = b.addSystemCommand(&.{
        "tar",
        "-czf",
        targz,
        "ninja",
    });
    tar.cwd = .{ .cwd_relative = b.getInstallPath(
        target_install_dir,
        ".",
    ) };
    tar.step.dependOn(install);
    return &tar.step;
}

const builtin = @import("builtin");
const std = @import("std");
