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
podman run -i --rm quay.io/coreos/butane -p -s <fcos-config.fcc > fcos-config.ign
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
./vm-create
```

Notice that it will take a few minutes to boot. We can get a console using
```
virsh console fcos
```

Once done, we can delete the VM using `./vm-destroy`.

### Generate the ISO

##### Build the container image

We have a VM running in the background, we will get back to it soon.

Now we are going to build a simple container image that will contain a basic
golang binary and systemd service in it.

Eventually, we are going to generate a bootable ISO that will be based on that contaienr image.

```
cd container-image/
podman build -t quay.io/ybettan/fcos:golang-binary .
podman push quay.io/ybettan/fcos:golang-binary
```

##### SSH to the machine

Use `virsh net-dhcp-leases default` in order to get the VM IP and then we can SSH to it.

```
ssh core@<ip>
sudo su #FIXME: Do we need to be su?
```

##### Create working directory

```
podman pull quay.io/coreos-assembler/coreos-assembler
```

The coreos-assmebler needs a working directory (same as git does).
```
mkdir fcos
cd fcos
```

[Go to source](https://github.com/coreos/coreos-assembler/blob/main/docs/building-fcos.md#create-a-build-working-directory)

##### Defining the cosa alias

Add the following as an alias:
```
cosa() {
   env | grep COREOS_ASSEMBLER
   local -r COREOS_ASSEMBLER_CONTAINER_LATEST="quay.io/coreos-assembler/coreos-assembler:latest"
   if [[ -z ${COREOS_ASSEMBLER_CONTAINER} ]] && $(podman image exists ${COREOS_ASSEMBLER_CONTAINER_LATEST}); then
       local -r cosa_build_date_str="$(podman inspect -f "{{.Created}}" ${COREOS_ASSEMBLER_CONTAINER_LATEST} | awk '{print $1}')"
       local -r cosa_build_date="$(date -d ${cosa_build_date_str} +%s)"
       if [[ $(date +%s) -ge $((cosa_build_date + 60*60*24*7)) ]] ; then
         echo -e "\e[0;33m----" >&2
         echo "The COSA container image is more that a week old and likely outdated." >&2
         echo "You should pull the latest version with:" >&2
         echo "podman pull ${COREOS_ASSEMBLER_CONTAINER_LATEST}" >&2
         echo -e "----\e[0m" >&2
         sleep 10
       fi
   fi
   set -x
   podman run --rm -ti --security-opt label=disable --privileged                                    \
              --uidmap=1000:0:1 --uidmap=0:1:1000 --uidmap 1001:1001:64536                          \
              -v ${PWD}:/srv/ --device /dev/kvm --device /dev/fuse                                  \
              --tmpfs /tmp -v /var/tmp:/var/tmp --name cosa                                         \
              ${COREOS_ASSEMBLER_CONFIG_GIT:+-v $COREOS_ASSEMBLER_CONFIG_GIT:/srv/src/config/:ro}   \
              ${COREOS_ASSEMBLER_GIT:+-v $COREOS_ASSEMBLER_GIT/src/:/usr/lib/coreos-assembler/:ro}  \
              ${COREOS_ASSEMBLER_CONTAINER_RUNTIME_ARGS}                                            \
              ${COREOS_ASSEMBLER_CONTAINER:-$COREOS_ASSEMBLER_CONTAINER_LATEST} "$@"
   rc=$?; set +x; return $rc
}
```

This is a bit more complicated than a simple alias, but it allows for hacking on the assembler or the configs and prints out the environment and the command that ultimately gets run. Let's step through each part:

podman run --rm -ti: standard container invocation
* --privileged: Note we're running as non root, so this is still safe (from the host's perspective)
* --security-opt label:disable: Disable SELinux isolation so we don't need to relabel the build directory
* --uidmap=1000:0:1 --uidmap=0:1:1000 --uidmap 1001:1001:64536: map the builder user to root in the user namespace where root in the user namespace is mapped to the calling user from the host. See this well formatted explanation of the complexities of user namespaces in rootless podman.
* --device /dev/kvm --device /dev/fuse: Bind in necessary devices
* --tmpfs: We want /tmp to go away when the container restarts; it's part of the "ABI" of /tmp
* -v /var/tmp:/var/tmp: Some cosa commands may allocate larger temporary files (e.g. supermin; forward this to the host)
* -v ${PWD}:/srv/: mount local working dir under /srv/ in container
* --name cosa: just a name, feel free to change it

The environment variables are special purpose:

* COREOS_ASSEMBLER_CONFIG_GIT: Allows you to specifiy a local directory that contains the configs for the ostree you are trying to compose.
* COREOS_ASSEMBLER_GIT: Allows you to specify a local directory that contains the CoreOS Assembler scripts. This allows for quick hacking on the assembler itself.
* COREOS_ASSEMBLER_CONTAINER_RUNTIME_ARGS: Allows for adding arbitrary mounts or args to the container runtime.
* COREOS_ASSEMBLER_CONTAINER: Allows for overriding the default assembler container which is currently quay.io/coreos-assembler/coreos-assembler:latest.

[go to source](https://github.com/coreos/coreos-assembler/blob/main/docs/building-fcos.md#define-a-bash-alias-to-run-cosa)

##### Running persistently

At this point, try `cosa shell` to start a shell inside the container.
From here, you can run `cosa ...` to invoke build commands.

[go to source](https://github.com/coreos/coreos-assembler/blob/main/docs/building-fcos.md#running-persistently)
