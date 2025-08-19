# orin-nano-l4t-prepare-and-flash

Script for downloading, preparing, and flashing a specified Jetson Linux
(L4T) release on Nvidia Orin Nano using Fedora for the host system.

This was last tested with Fedora 40.

Download and prepare L4T release 36.4.4:

```
sudo ./orin-nano-l4t-prepare-and-flash.sh -g -v 36.4.4
```

After putting the Orin Nano in Forced Recovery mode, flash the downloaded
L4T release:

```
sudo ./orin-nano-l4t-prepare-and-flash.sh -f

```
