# image-composer

### Create the VM evn

Create a VM using virt-manager with and running RHEL as root.
* 4 CPUs
* 4GB of RAM
* 40GB of disk

The VM for image builder must be running and subscribed to Red Hat Subscription
Manager (RHSM) or Red Hat Satellite.

### Prerequisites

We will use [image-builder](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/composing_a_customized_rhel_system_image/index) to build custom RHEL/R4E images.

We also need to install some packages
```
dnf install -y osbuild-composer composer-cli
```

And enable the `osbuild-composer.socket`
```
systemctl enable --now osbuild-composer.socket
```

### Creating a Bluepring

Custom images are created from a blueprint in TOML format which specifies
customization parameters.

For our demo, we are including a dummy kernel-module and a administrator user.

Check [blueprint-kmm-kmod-container.toml](./blueprint-kmm-kmod-container.toml).
The full list of possible image customization can be found [here](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/composing_a_customized_rhel_system_image/creating-system-images-with-composer-command-line-interface_composing-a-customized-rhel-system-image#image-customizations_creating-system-images-with-composer-command-line-interface).
```
composer-cli blueprints push blueprint-kmm-kmod-container.toml
```

We can list the pushed blueprints using
```
composer-cli blueprints list
```

We can also see all the dependnecies that are going to be installed using
```
composer-cli blueprints depsolve kmm-kmod-container
```

### Edge-container creation

OSTree commits aren't bootable artifacts.
In order to "boot" them we need:
* An http server with the OSTree commit
* An installation ISO
* A kickstart file that instructs Anaconda (Fedora installer) to use the OSTree commit from the HTTP server

```
 _________________          ____________________________
|                 |        |                            |
|                 |------->| Fedora VM with mounted ISO |
|                 |        |  - Anaconda                |
|  Fedora Host OS |        |____________________________|
|                 |                |
|                 |         _______|________________________
|                 |        |                                |
|                 |------->| Fedora container running httpd |
|_________________|        |  serving content of the tarball|
                           |  and the kickstart file        |
                           |________________________________|
```

This sounds complicated, but `osbuild-composer` offers an easy way to generate a
container with a web server and the desired OSTree commit. We will use the `composer-cli`
to generate this container on the `osbuild-composer` service.
```
composer-cli compose start kmm-kmod-container edge-container
```
while `edge-container` is the image type.
FIXME: try `composer-cli compose start kmm-kmod-container qcow2`

The above command will take some time and we can follow the progress using
```
composer-cli compose status
```

Now, we can download the edge-container image
```
composer-cli compose image <id>
```

We can also use
```
composer-cli compose results <id>
```
to gat a `tar` that will contain both, the image and additional data such as
the `json` pipeline for `osbuild` and the logs.

We can start the image using `podman`
```
podman load -i <tar-file>
podman tag <id-returned-by-podman-load> localhost/edge-container
podman run --rm --detach --name edge-container --publish 8080:8080 localhost/edge-container
```

### ISO creation

We will need a new blueprint in order to generate the ISO.
Check [blueprint-kmm-kmod-iso.toml](./blueprint-kmm-kmod-iso.toml).

Please take note as to the lack of customizations. Including customizations here
would overlap with the first blueprint and installer generation would not be possible.

As with the first blueprint, we need to
```
composer-cli blueprints push blueprint-kmm-kmod-iso.toml
composer-cli blueprints list
```

With the edge-container running, we can now generate the actual ISO:

```
composer-cli compose start-ostree --ref rhel/9/x86_64/edge --url http://localhost:8080/repo kmm-kmod-iso edge-installer
composer-cli compose status
```
* `edge-installer` is the image type.
* The above `--ref` which is served by the edge-container we've started earlier.

Onced finished, download the ISO
```
composer-cli compose image <id>
```
or
```
composer-cli compose results <id>
```

### Summarizing moving parts

```
  +-----------------------------------------+
  |                                         v
+------------+     +----------------+     +-------------+
| OS Builder | --> | Edge Container | --> | Install ISO |
+------------+     +----------------+     +-------------+
```

### Testing the ISO

Run the VM
```
./vm-create-image-builder /root/go/src/github.com/image-composer/custom_r4e.iso
```

Get a console the the VM by running
```
virsh console r4e
```

Then, pres the <up> arrow key to get into the grub menu and on
`Install Red Hat Enterprise Linux 9.2` press `e` to edit (this will be opened in nano).
We nee to make sure that the `initrd` section of the command is still in its own
new line.

Remove the `quiet` kernel-arg and replace it with `console=ttyS0` and then
press `Ctrl-x` to save and exit.

We should then get console for the installation process.

When the `anaconda` installation starts we will probably need to configure the
installation disk and the network.

If we get something like `Kickstart insufficient` in the "Installation Destination"
then we will press `1` and then enter to enter the disk configuration menue.
Follow up the default configurations (use all space, LVM)

Then if we have a `Unknown` in the "Network configuration" then press `3`.
Then press `1` and choose `dhcp`, press `7` and then `8` for connecting after reboot
and applying the configurations to the installer.

Finally, press `b` for booting.

After the reboot, we can SSH to the machine.

### Troubleshooting

Useful commands for troubleshooting image composes

* Show the log of a compose
```
composer-cli compose log <id>
```

* View diagnostics messages produced by the composer
```
journalctl -t osbuild-composer
```

* View diagnostics messages produced by the worker
```
journalctl -t osbuild-worker
```

### Links

* [image-builder docs](https://www.osbuild.org/guides/introduction.html)
* https://github.com/kwozyman/rhel-edge-demo
