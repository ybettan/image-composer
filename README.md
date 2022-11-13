# image-composer

### Prerequisites

The CoreOS-assember (`cosa`) is encapsulated in a container but runs as a privileged container that will create disk images on the host, therefore, all the work is going to be done a VM.

See [coreos-assembler prerequisites](https://github.com/coreos/coreos-assembler/blob/03dd8da933722902b9775c823af68afa5187f774/docs/building-fcos.md#getting-started---prerequisites)

##### Download the Fedora-CoreOS image

Now, we are going to download the Fedora-CoreOS disk image for Qemu. We
are going to use that disk in order to boot a VM from it later on this
tutorial.

```
curl -L https://builds.coreos.fedoraproject.org/prod/streams/stable/builds/36.20220716.3.1/x86_64/fedora-coreos-36.20220716.3.1-qemu.x86_64.qcow2.xz -o fedora-coreos-36.20220716.3.1-qemu.x86_64.qcow2.xz
```

And extract it.

```
unxz fedora-coreos-36.20220716.3.1-qemu.x86_64.qcow2.xz
```

##### Create an ignition file

Ignition files are a way to configure a CoreOS machine at boot time.

We are going to create a simple ignition file that add your public SSH key to
the machine so you can SSH to it after the installation.

Edit `fcos-config.fcc` and put your public SSH key in it. Then we are going to
generate the ignition file from that yaml.

```
podman run -i --rm quay.io/coreos/fcct -p -s <fcos-config.fcc > fcos-config.ign
```

And make sure it was created correctly by inspecting `fcos-config.ign`.

##### Configuring SELinux

We are goign to use `virt` in order to install the VM, therefore, we need to
add a SELinux rule to allow `virt` to read the ignition file.

For now we are just going to disable SELinux.

* Check SELinux status: `getenforce`
* Disable SELinux: `setenforce 0` (status should become `permissive`)
* Enable SELinux: `setenforce 1` (status should become `enforcing`)

##### Install the virtual machine

```
./create-vm
```

Notice that it will take a few minutes to boot. We can get a console using
```
virsh console fcos
```

##### SSH to the machine

Use `virsh net-dhcp-leases default` in order to get the VM IP and then we can SSH to it.

```
ssh core@<ip>
sudo su #FIXME: Do we need to be su?
```

### Build the container image

Now we are going to build a simple container image that will contains a basic
golang binary and systemd service in it.

Eventually, we are going to generate a bootable ISO that will be based on that contaienr image.

```
cd container-image/
podman build -t quay.io/ybettan/fcos:golang-binary .
podman push quay.io/ybettan/fcos:golang-binary
```

### Generate the ISO

