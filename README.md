# Limine Linux Deploy

Limine Linux Deploy is a dead simple utility meant to generate a Limine configuration file based on a default, simple configuration file.

## Note regarding kernels outside of EFI System Partition

If, for some reason, your kernel resides outside of the ESP (perhaps it lives in /boot even in an EFI-based system, or you have a BIOS-based system), Limine will only be able to find its configuration file (and thus load your kernel) if the partition containing the kernel (usually root) is ext2/3/4.

If you have a BIOS-based system, you can always create a separate FAT32 partition, similar to the ESP, and toggle the boot flag so that your system boots from that partition instead of root.

Alternatively, on any system, you may choose to mount the ESP/the separate FAT32 partition directly as /boot if your distribution uses that path to put kernels and other shenanigans.

## Example

``./LimineLinuxDeploy --bootdir /boot/efi --defconf limine.default --outconf limine.cfg``

**limine.default**:
```
[linux]
timeout = 0
distributor = AnErrupTion
cmdline = loglevel=4
```