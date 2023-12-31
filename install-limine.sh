#!/bin/sh

echo Limine Linux Deploy - Installer for AMD64

if [ ! -f /bin/zig ]; then
	echo Error: Zig is not present in PATH!
	exit
fi

echo Boot directory:
read bootdir

if [ ! -d "${bootdir}" ]; then
	echo Error: boot directory does not exist!
	exit
fi

echo Disk to install Limine to:
read disk

echo EFI System Partition number (can be ignored on BIOS):
read espnum

echo Bootloader timeout:
read timeout

cd /tmp

echo Downloading Limine...
git clone https://github.com/limine-bootloader/limine -b v5.x-branch-binary

echo Downloading Limine Linux Deploy...
git clone https://github.com/AnErrupTion/LimineLinuxDeploy

echo Building Limine Linux Deploy...
cd LimineLinuxDeploy
zig build
cd ..

if [ -d /sys/firmware/efi ]; then
	# System has been booted in UEFI mode

	# Create EFI/limine directory if not already present
	mkdir -p "${bootdir}/EFI/limine"

	# Copy EFI executable
	cp limine/BOOTX64.EFI "${bootdir}/EFI/limine/amd64.efi"

	# Create new EFI boot entry
	efibootmgr -c -d ${disk} -p ${espnum} -L "limine" -l "\EFI\limine\amd64.efi"
else
	# System has been booted in BIOS mode

	# Copy stage 2 file
	cp limine/limine-bios.sys "${bootdir}/limine-bios.sys"

	# Build Limine deployment tool execcutable
	echo Building Limine deployment tool...
	cd limine
	make -j$(nproc)
	cd ..

	# Deploy Limine to device
	./limine/limine bios-install ${disk}
fi

# Generate configuration file
./LimineLinuxDeploy/zig-out/bin/LimineLinuxDeploy --bootdir "${bootdir}" --timeout ${timeout} --distributor "Limine Linux Deploy" --cmdline "$(cat /proc/cmdline)" --outconf "${bootdir}/limine.cfg"

# Clean up
rm -rf limine
rm -rf LimineLinuxDeploy