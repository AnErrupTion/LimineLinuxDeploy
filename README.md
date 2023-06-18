# Limine Linux Deploy

Limine Linux Deploy is a dead simple utility meant to generate a Limine configuration file based on a default configuration file.

## Example

``./LimineLinuxDeploy --esp-directory /boot/efi --default-config limine.default --output-config limine.cfg``

**limine.default**:
```
[linux]
timeout = 0
distributor = AnErrupTion
cmdline = loglevel=4
```