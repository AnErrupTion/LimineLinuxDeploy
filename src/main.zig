const std = @import("std");
const ini = @import("ini.zig");

const DefaultConfig = struct {
    linux: struct {
        timeout: u64,
        distributor: []const u8,
        cmdline: []const u8,
    },
};

pub fn main() !void {
    // Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const cwd = std.fs.cwd();

    // Read command line arguments
    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 7) {
        std.debug.print("Correct usage: LimineLinuxDeploy --boot-directory <path> --default-config <path> --output-config <path>", .{});
        std.os.exit(1);
    }

    var boot_directory: []const u8 = "";
    var default_config: []const u8 = "";
    var output_config: []const u8 = "";
    var index: u32 = 1;

    while (index < args.len) : (index += 1) {
        var arg = args[index];

        if (std.mem.eql(u8, arg, "--boot-directory")) {
            index += 1;
            boot_directory = args[index];
        } else if (std.mem.eql(u8, arg, "--default-config")) {
            index += 1;
            default_config = args[index];
        } else if (std.mem.eql(u8, arg, "--output-config")) {
            index += 1;
            output_config = args[index];
        } else {
            std.debug.print("Error: Invalid argument \"{s}\"", .{arg});
            std.os.exit(1);
        }
    }

    // Read default configuration file
    var buffer = try cwd.readFileAlloc(allocator, default_config, 16 * 1024);
    defer allocator.free(buffer);

    var config = try ini.readToStruct(DefaultConfig, buffer);

    var kernel_version: []const u8 = "";
    var disk_identifier: []const u8 = "";
    var kernel_path: []const u8 = "";

    var modules_path = std.ArrayList([]const u8).init(allocator);
    defer modules_path.deinit();

    // Iterate over all files in the chosen directory
    var boot_iterable_directory = try std.fs.openIterableDirAbsolute(boot_directory, .{});
    defer boot_iterable_directory.close();

    var iterator = boot_iterable_directory.iterate();

    while (try iterator.next()) |item| {
        var name = item.name;

        if (std.mem.containsAtLeast(u8, name, 1, "vmlinuz-")) {
            // If it contains "vmlinuz-", then it's most likely the kernel file

            var hyphen_index = std.mem.indexOf(u8, name, "-");

            if (hyphen_index == null) unreachable;

            kernel_path = name;
            kernel_version = name[(hyphen_index.? + 1)..];
        } else if (std.mem.endsWith(u8, name, ".img")) {
            // Else, if it ends in ".img", then it's most likely a module file

            var module_path = try std.fmt.allocPrint(allocator, "MODULE_PATH=boot:///{s}", .{name});

            try modules_path.append(module_path);
        }
    }

    // Read /etc/fstab file
    var fstab_file = try std.fs.openFileAbsolute("/etc/fstab", .{});
    defer fstab_file.close();

    var fstab_buffer = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(fstab_buffer);

    _ = try fstab_file.readAll(fstab_buffer);

    var fstab_lines = std.mem.splitSequence(u8, fstab_buffer, "\n");

    while (fstab_lines.next()) |line| {
        // If it contains " / " then it's most likely the line with the root partition
        if (!std.mem.containsAtLeast(u8, line, 1, " / ")) {
            continue;
        }

        var fstab_options = std.mem.splitSequence(u8, line, " ");

        disk_identifier = fstab_options.first();
    }

    // Join array of modules path
    var all_modules = try std.mem.join(allocator, "", modules_path.items);
    defer allocator.free(all_modules);

    // Create Limine config itself
    var limine_cfg = try std.fmt.allocPrint(
        allocator,
        "TIMEOUT={d}\nINTERFACE_BRANDING={s}\n:Linux {s}\nPROTOCOL=linux\nCMDLINE=root={s} {s}\nKERNEL_PATH=boot:///{s}\n{s}",
        .{ config.linux.timeout, config.linux.distributor, kernel_version, disk_identifier, config.linux.cmdline, kernel_path, all_modules },
    );
    defer allocator.free(limine_cfg);

    // Write to file
    var cfg_file = try cwd.createFile(output_config, .{});
    defer cfg_file.close();

    try cfg_file.writeAll(limine_cfg);

    for (modules_path.items) |item| {
        allocator.free(item);
    }

    std.log.info("Successfully generated a Limine configuration file! Make sure to put it under {s}. ;)\n", .{boot_directory});
}
