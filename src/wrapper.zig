////
// DO NOT EDIT THIS FILE
////

const builtin = @import("builtin");
const build_options = @import("build_options");
const std = @import("std");
const json = std.json;
const log = std.log;
const fs = std.fs;

const Sha1 = std.crypto.hash.Sha1;
const Base64 = std.base64.url_safe_no_pad.Encoder;

// Foilz Archive Util
const foilz = @import("archiver.zig");

// Maint utils
const logger = @import("logger.zig");
const maint = @import("maintenance.zig");
const shutil = @import("shutil.zig");
const win_asni = @cImport(@cInclude("win_ansi_fix.h"));

// Install dir suffix
const install_suffix = ".burrito";

const plugin = @import("burrito_plugin");

const metadata = @import("metadata.zig");
const MetaStruct = metadata.MetaStruct;

// Payload
pub const FOILZ_PAYLOAD = @embedFile("../payload.foilz.xz");
pub const RELEASE_METADATA_JSON = @embedFile("../_metadata.json");

// Memory allocator
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var allocator = arena.allocator();

// Windows cmd argument parser
const windows = std.os.windows;
const LPCWSTR = windows.LPCWSTR;
const LPWSTR = windows.LPWSTR;
pub extern "kernel32" fn GetCommandLineW() LPWSTR;
pub extern "shell32" fn CommandLineToArgvW(lpCmdLine: LPCWSTR, out_pNumArgs: *c_int) ?[*]LPWSTR;

pub fn main() anyerror!void {
    log.debug("Size of embedded payload is: {}", .{FOILZ_PAYLOAD.len});

    // If this is not a production build, we always want a clean install
    const wants_clean_install = !build_options.IS_PROD;

    const meta = metadata.parse(allocator, RELEASE_METADATA_JSON).?;

    const install_dir = (try get_install_dir(&meta))[0..];
    const metadata_path = try fs.path.join(allocator, &[_][]const u8{ install_dir, "_metadata.json" });

    log.debug("Install Directory: {s}", .{install_dir});
    log.debug("Metadata path: {s}", .{metadata_path});

    // Ensure the destination directory is created
    try std.fs.cwd().makePath(install_dir);

    // If the metadata file exists, don't install again
    var needs_install: bool = false;
    std.fs.accessAbsolute(metadata_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            needs_install = true;
        } else {
            log.err("We failed to open the destination directory with an unexpected error: {s}", .{err});
            return;
        }
    };

    var args: ?[][]u8 = null;

    // Get argvs -- on Windows we need to call CommandLineToArgvW() with GetCommandLineW()
    if (builtin.os.tag == .windows) {
        // Windows arguments
        var arg_count: c_int = undefined;
        var raw_args = CommandLineToArgvW(GetCommandLineW(), &arg_count);
        var windows_arg_list = std.ArrayList([]u8).init(allocator);
        var i: c_int = 0;
        while (i < arg_count) : (i += 1) {
            var index = @intCast(usize, i);
            var length = std.mem.len(raw_args.?[index]);
            const argument = try std.unicode.utf16leToUtf8Alloc(allocator, raw_args.?[index][0..length]);
            try windows_arg_list.append(argument);
        }

        args = windows_arg_list.items;
    } else {
        // POSIX arguments
        args = try std.process.argsAlloc(allocator);
    }

    const args_trimmed = args.?[1..];

    const args_string = try std.mem.join(allocator, " ", args_trimmed);
    log.debug("Passing args string: {s}", .{args_string});

    // Execute plugin code
    plugin.burrito_plugin_entry(install_dir, RELEASE_METADATA_JSON);

    // If we need an install, install the payload onto the target machine
    if (needs_install or wants_clean_install) {
        try do_payload_install(install_dir, metadata_path);
    } else {
        log.debug("Skipping archive unpacking, this machine already has the app installed!", .{});
    }

    // Check for maintenance commands
    if (args_trimmed.len > 0 and std.mem.eql(u8, args_trimmed[0], "maintenance")) {
        logger.info("Entering {s} maintenance mode...", .{build_options.RELEASE_NAME});
        logger.info("Build metadata: {s}", .{RELEASE_METADATA_JSON});
        try maint.do_maint(args_trimmed[1..], install_dir);
        return;
    }

    // Clean up older versions
    const base_install_path = try get_base_install_dir();
    try maint.do_clean_old_versions(base_install_path, install_dir);

    // Get Env
    var env_map = try std.process.getEnvMap(allocator);

    // Add _IS_TTY env variable
    if (shutil.is_tty()) {
        try env_map.put("_IS_TTY", "1");
    } else {
        try env_map.put("_IS_TTY", "0");
    }

    // Get name of the exe (useful to pass into argv for the child erlang process)
    const exe_path = try fs.selfExePathAlloc(allocator);
    const exe_name = fs.path.basename(exe_path);

    // Compute the full base bin path
    const base_bin_path = try fs.path.join(allocator, &[_][]const u8{ install_dir, "bin", build_options.RELEASE_NAME });

    log.debug("Base Executable Path: {s}", .{base_bin_path});

    // Windows does not have a REAL execve, so instead the wrapper will hang around while the Erlang process runs
    // We'll use a ChildProcess with stdin and out being inherited
    if (builtin.os.tag == .windows) {
        // Fix up Windows 10+ consoles having ANSI escape support, but only if we set some flags
        win_asni.enable_virtual_term();

        const bat_path = try std.mem.concat(allocator, u8, &[_][]const u8{ base_bin_path, ".bat" });

        // HACK: To get aroung the many issues with escape characters (like ", ', =, !, and %) in Windows
        // we will encode each argument as a base64 string, these will be then be decoded using `Burrito.Util.Args.get_arguments/0`.
        try env_map.put("_ARGUMENTS_ENCODED", "1");
        var encoded_list = std.ArrayList([]u8).init(allocator);
        defer encoded_list.deinit();

        for (args_trimmed) |argument| {
            const encoded_len = std.base64.standard_no_pad.Encoder.calcSize(argument.len);
            const argument_encoded = try allocator.alloc(u8, encoded_len);
            _ = std.base64.standard_no_pad.Encoder.encode(argument_encoded, argument);
            try encoded_list.append(argument_encoded);
        }

        const win_args = &[_][]const u8{ bat_path, "start", exe_name };
        const final_args = try std.mem.concat(allocator, []const u8, &.{ win_args, encoded_list.items });

        const win_child_proc = try std.ChildProcess.init(final_args, allocator);
        win_child_proc.env_map = &env_map;
        win_child_proc.stdout_behavior = .Inherit;
        win_child_proc.stdin_behavior = .Inherit;

        log.debug("CLI List: {s}", .{final_args});

        _ = try win_child_proc.spawnAndWait();
    } else {
        const cli = &[_][]const u8{ base_bin_path, "start", exe_name, args_string };
        log.debug("CLI List: {s}", .{cli});
        return std.process.execve(allocator, cli, &env_map);
    }
}

fn do_payload_install(install_dir: []const u8, metadata_path: []const u8) !void {
    // Unpack the files
    try foilz.unpack_files(FOILZ_PAYLOAD, install_dir, build_options.UNCOMPRESSED_SIZE);

    // Write metadata file
    const file = try fs.createFileAbsolute(metadata_path, .{ .truncate = true });
    try file.writeAll(RELEASE_METADATA_JSON);
}

fn get_base_install_dir() ![]const u8 {
    // If we have a override for the install path, use that, otherwise, continue to return
    // the standard install path
    const upper_name = try std.ascii.allocUpperString(allocator, build_options.RELEASE_NAME);
    const env_install_dir_name = try std.fmt.allocPrint(allocator, "{s}_INSTALL_DIR", .{upper_name});

    if (std.process.getEnvVarOwned(allocator, env_install_dir_name)) |new_path| {
        logger.info("Install path is being overriden using `{s}`", .{env_install_dir_name});
        logger.info("New install path is: {s}", .{new_path});
        return try fs.path.join(allocator, &[_][]const u8{ new_path, install_suffix });
    } else |err| switch (err) {
        error.InvalidUtf8 => {},
        error.EnvironmentVariableNotFound => {},
        error.OutOfMemory => {},
    }

    const app_dir = fs.getAppDataDir(allocator, install_suffix) catch {
        install_dir_error();
        return "";
    };

    return app_dir;
}

fn get_install_dir(meta: *const MetaStruct) ![]u8 {
    // Combine the hash of the payload and a base dir to get a safe install directory
    const base_install_path = try get_base_install_dir();

    // Parse the ERTS version and app version from the metadata JSON string
    const dir_name = try std.fmt.allocPrint(allocator, "{s}_erts-{s}_{s}", .{ build_options.RELEASE_NAME, meta.erts_version, meta.app_version });

    // Ensure that base directory is created
    std.os.mkdir(base_install_path, 0o755) catch |err| {
        if (err != error.PathAlreadyExists) {
            install_dir_error();
            return "";
        }
    };

    // Construct the full app install path
    const name = fs.path.join(allocator, &[_][]const u8{ base_install_path, dir_name }) catch {
        install_dir_error();
        return "";
    };

    return name;
}

fn install_dir_error() void {
    const upper_name = std.ascii.allocUpperString(allocator, build_options.RELEASE_NAME) catch {
        return;
    };
    const env_install_dir_name = std.fmt.allocPrint(allocator, "{s}_INSTALL_DIR", .{upper_name}) catch {
        return;
    };

    logger.err("We could not install this application to the default directory.", .{});
    logger.err("This may be due to a permission error.", .{});
    logger.err("Please override the default {s} install directory using the `{s}` environment variable.", .{ build_options.RELEASE_NAME, env_install_dir_name });
    logger.err("On Linux or MacOS you can run the command: `export {s}=/some/other/path`", .{env_install_dir_name});
    logger.err("On Windows you can use: `SET {s}=D:\\some\\other\\path`", .{env_install_dir_name});
    std.process.exit(1);
}
