const std = @import("std");
const clap = @import("clap");
const ini = @import("ini");

const DefaultConfig = struct {
    linux: struct {
        timeout: u64,
        distributor: []const u8,
        cmdline: []const u8,
    },
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

var boot_directory: []const u8 = "";
var default_config: []const u8 = "";
var output_config: []const u8 = "";
var timeout: u64 = 0;
var distributor: []const u8 = "";
var cmdline: []const u8 = "";

var disk_identifier: []const u8 = undefined;
var kernels_path: std.ArrayList([]const u8) = undefined;
var modules_path: std.ArrayList([]const u8) = undefined;

var permanent_buffers: std.ArrayList([]u8) = undefined;

pub fn main() !void {
    defer _ = gpa.deinit();

    // Initialize permanent buffers list
    permanent_buffers = std.ArrayList([]u8).init(allocator);
    defer permanent_buffers.deinit();

    // Read command line arguments
    const params = comptime clap.parseParamsComptime(
        \\-h, --help                Displays all arguments.
        \\-b, --bootdir <str>       Specifies the boot directory containing the kernel images, and potentially modules as well.
        \\-c, --defconf <str>       Specifies the default configuration file. Can be omitted in favor of inline arguments.
        \\-o, --outconf <str>       Specifies the output configuration file.
        \\-t, --timeout <u64>       Specifies the bootloader timeout. Can be omitted in favor of the default configuration file.
        \\-d, --distributor <str>   Specifies the name of the distributor. Can be omitted in favor of the default configuration file.
        \\-m, --cmdline <str>       Specifies the kernel command line. Can be omitted in favor of the default configuration file.
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{ .diagnostic = &diag }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
        std.os.exit(0);
    }
    if (res.args.bootdir) |s| boot_directory = s;
    if (res.args.defconf) |s| default_config = s;
    if (res.args.outconf) |s| output_config = s;
    if (res.args.timeout) |n| timeout = n;
    if (res.args.distributor) |s| distributor = s;
    if (res.args.cmdline) |s| cmdline = s;

    // Read default configuration file, if any
    if (default_config.len > 0) {
        var buffer = try std.fs.cwd().readFileAlloc(allocator, default_config, 16 * 1024);
        try permanent_buffers.append(buffer);

        var config = try ini.readToStruct(DefaultConfig, buffer);

        timeout = config.linux.timeout;
        distributor = config.linux.distributor;
        cmdline = config.linux.cmdline;
    }

    kernels_path = std.ArrayList([]const u8).init(allocator);
    defer kernels_path.deinit();

    modules_path = std.ArrayList([]const u8).init(allocator);
    defer modules_path.deinit();

    // Iterate over all files in the chosen directory to find all kernels and modules
    try read_boot_directory();

    // Read /etc/fstab file to find the identifier of the root partition
    try read_fstab();

    // Create Limine config itself
    try write_config();

    // Free all permanent buffers
    for (permanent_buffers.items) |item| allocator.free(item);

    std.log.info("Successfully generated a Limine configuration file! Make sure to put it under {s}. ;)\n", .{boot_directory});
}

fn read_boot_directory() !void {
    var boot_iterable_directory = try std.fs.openIterableDirAbsolute(boot_directory, .{});
    defer boot_iterable_directory.close();

    var iterator = boot_iterable_directory.iterate();

    while (try iterator.next()) |item| {
        var name = item.name;

        if (std.mem.containsAtLeast(u8, name, 1, "vmlinuz-")) {
            // If it contains "vmlinuz-", then it's most likely the kernel file

            var kernel_path = try std.fmt.allocPrint(allocator, "KERNEL_PATH=boot:///{s}", .{name});

            try permanent_buffers.append(kernel_path);
            try kernels_path.append(kernel_path);
        } else if (std.mem.endsWith(u8, name, ".img")) {
            // Else, if it ends in ".img", then it's most likely a module file

            var module_path = try std.fmt.allocPrint(allocator, "MODULE_PATH=boot:///{s}", .{name});

            try permanent_buffers.append(module_path);
            try modules_path.append(module_path);
        }
    }
}

fn read_fstab() !void {
    var fstab_file = try std.fs.openFileAbsolute("/etc/fstab", .{});
    defer fstab_file.close();

    var fstab_buffer = try allocator.alloc(u8, 16 * 1024);
    try permanent_buffers.append(fstab_buffer);

    _ = try fstab_file.readAll(fstab_buffer);

    var fstab_lines = std.mem.splitSequence(u8, fstab_buffer, "\n");

    while (fstab_lines.next()) |line| {
        // If it contains " / " then it's most likely the root partition
        if (!std.mem.containsAtLeast(u8, line, 1, " / ")) continue;

        var fstab_options = std.mem.splitSequence(u8, line, " ");

        disk_identifier = fstab_options.first();
    }
}

fn write_config() !void {
    var limine_cfg = std.ArrayList([]const u8).init(allocator);
    defer limine_cfg.deinit();

    // Global configuration
    var global_config = try std.fmt.allocPrint(allocator, "TIMEOUT={d}\nINTERFACE_BRANDING={s}", .{ timeout, distributor });
    defer allocator.free(global_config);

    try limine_cfg.append(global_config);

    // Kernel command line
    var kernel_cmdline = try std.fmt.allocPrint(allocator, "CMDLINE=root={s} {s}", .{ disk_identifier, cmdline });
    defer allocator.free(kernel_cmdline);

    // Kernel entries
    for (kernels_path.items) |kernel_path| {
        var kernel_hyphen_index = std.mem.indexOf(u8, kernel_path, "-");
        var kernel_version = kernel_path[(kernel_hyphen_index.? + 1)..];
        var kernel_name = try std.fmt.allocPrint(allocator, ":Linux {s}", .{kernel_version});

        try permanent_buffers.append(kernel_name);

        try limine_cfg.append(kernel_name);
        try limine_cfg.append("PROTOCOL=linux");
        try limine_cfg.append(kernel_cmdline);
        try limine_cfg.append(kernel_path);

        // Find associated modules with kernel
        for (modules_path.items) |module_path| {
            if (std.mem.containsAtLeast(u8, module_path, 1, kernel_version)) {
                // It's a module that can be loaded on that specific kernel, so we add it
                try limine_cfg.append(module_path);
                continue;
            }

            var module_hyphen_index = std.mem.indexOf(u8, module_path, "-");

            if (module_hyphen_index == null) {
                // It's a module that can be loaded on any kernel, so we add it
                try limine_cfg.append(module_path);
                continue;
            }

            var next_char = module_path[module_hyphen_index.? + 1];

            if (!std.ascii.isDigit(next_char)) {
                // It's a module that can be loaded on any kernel, so we add it
                try limine_cfg.append(module_path);
                continue;
            }
        }
    }

    // Write to file
    var cfg_file = try std.fs.cwd().createFile(output_config, .{});
    defer cfg_file.close();

    var configuration = try std.mem.join(allocator, "\n", limine_cfg.items);
    defer allocator.free(configuration);

    try cfg_file.writeAll(configuration);
}
