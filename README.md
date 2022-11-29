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

### Set up the environment

##### SSH to the machine

Use `virsh net-dhcp-leases default` in order to get the VM IP and then we can SSH to it.

```
ssh core@<ip>
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

Add the following as an alias (don't forget to source `~/.aliases`):
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
* `--privileged`: Note we're running as non root, so this is still safe (from the host's perspective)
* `--security-opt label:disable`: Disable SELinux isolation so we don't need to relabel the build directory
* `--uidmap=1000:0:1 --uidmap=0:1:1000 --uidmap 1001:1001:64536`: map the builder user to root in the user namespace where root in the user namespace is mapped to the calling user from the host. See this well formatted explanation of the complexities of user namespaces in rootless podman.
* `--device /dev/kvm --device /dev/fuse`: Bind in necessary devices
* `--tmpfs`: We want /tmp to go away when the container restarts; it's part of the "ABI" of /tmp
* `-v /var/tmp:/var/tmp`: Some cosa commands may allocate larger temporary files (e.g. supermin; forward this to the host)
* `-v ${PWD}:/srv/`: mount local working dir under /srv/ in container
* `--name cosa`: just a name, feel free to change it

The environment variables are special purpose:

* `COREOS_ASSEMBLER_CONFIG_GIT`: Allows you to specifiy a local directory that contains the configs for the ostree you are trying to compose.
* `COREOS_ASSEMBLER_GIT`: Allows you to specify a local directory that contains the CoreOS Assembler scripts. This allows for quick hacking on the assembler itself.
* `COREOS_ASSEMBLER_CONTAINER_RUNTIME_ARGS`: Allows for adding arbitrary mounts or args to the container runtime.
* `COREOS_ASSEMBLER_CONTAINER`: Allows for overriding the default assembler container which is currently quay.io/coreos-assembler/coreos-assembler:latest.

[go to source](https://github.com/coreos/coreos-assembler/blob/main/docs/building-fcos.md#define-a-bash-alias-to-run-cosa)

##### Running persistently

At this point, try `cosa shell` to start a shell inside the container.
From here, you can run `cosa ...` to invoke build commands.

[go to source](https://github.com/coreos/coreos-assembler/blob/main/docs/building-fcos.md#running-persistently)

##### Initializing

Initializing will clone the specified configuration repo, and create various directories/state such as the OSTree repository.

```
cosa init https://github.com/coreos/fedora-coreos-config
```

The specified git repository will be cloned into `$PWD/src/config/`.
We can see other directories created such as `builds`, `cache`, `overrides` and `tmp`.

[go to source](https://github.com/coreos/coreos-assembler/blob/main/docs/building-fcos.md#initializing)

### Generate a vanila FCOS ISO

First, we fetch all the metadata and packages

```
cosa fetch
```
And now we can build from these inputs

```
cosa build metal
```

Each build will create a new directory in `${PWD}/builds/`, containing the generated OSTree commit (as a tarball) and the qemu VM image.

Next, rerun cosa build and notice the system correctly deduces that nothing changed.
You can run `cosa fetch` again to check for updated RPMs.

We should be able to generate the ISO now
```
cosa buildextend-live --fast
```

[go to source](https://github.com/coreos/coreos-assembler/blob/main/docs/building-fcos.md#performing-a-build)

### Generate a falvored FCOS ISO by changing the config repo

##### Prerequisites

We will need to install the `libblkid-devel` package first.
```
sudo yum install libblkid-devel
```

##### Add a new overlay

FIXME: add a real overly instead of just updating the README.
FIXME: update the `05core` overlay instead of `15fcos`
Add some lines to `src/config/overlay.d/15fcos/usr/lib/dracut/modules.d/50ignition-conf-fcos/README.md` and then run
```
cosa fetch # do we need fetch?
cosa build metal
cosa buildextend-live --fast
```

Running a VM with that ISO should conain the updated `/usr/lib/dracut/modules.d/50ignition-conf-fcos/README.md`
on the new filesystem.

### Generate a falvored FCOS ISO by adding layers to the ociarchive

##### Prerequisites

We need to install [umoci](https://github.com/opencontainers/umoci).
We are going to download umoci 0.4.7 in this demo.

##### Some background regarding OCI

First let's extract the `ociarchive` content and inspect it.
```
mkdir fedora-coreos-image-spec
tar -xvf builds/latest/x86_64/fedora-coreos-<...>.dev.0-ostree.x86_64.ociarchive -C fedora-coreos-image-spec
cd fedora-coreos-image-spec
```

The `index.json` file, represent the manifest list. In simple words:
* each manifest is a container image.
* if we have multiple tags of an image then it translates to multiple manifests in the list while the tag is basically just an annotation
* if the image was build for multiple architectures then we will have a manifest for each one of them.
In our case we just have a single manifest in the list:
```
[coreos-assembler]$ cat fedora-coreos-image-spec/index.json | jq
{
  "schemaVersion": 2,
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:3d051a6ea78d5b3f289b87523dda34b72e098aa8ce13003af5ff6138bc790e75",
      "size": 8264,
      "annotations": {
        "org.opencontainers.image.ref.name": "latest"
      }
    }
  ]
}
```

In order to see the content of that manifest we can run:
```
[coreos-assembler]$ cat fedora-coreos-image-spec/blobs/sha256/3d051a6ea78d5b3f289b87523dda34b72e098aa8ce13003af5ff6138bc790e75 | jq
{
  "config": {
    "digest": "sha256:6071ea068284c515df8c555986b3401e9614edb12e4b399d91e932acc3cb6beb",
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "size": 9130
  },
  "layers": [
    {
      "digest": "sha256:2fb3e29b38db803dd51dd4855764420f3b8ce3580ba4f1df43611707c359bf5d",
      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
      "size": 1443197
    },
...
    {
      "digest": "sha256:7ad6c26555d465cde2a7af0a02e9701453c25bf0926ff6ba6858c62552ccc529",
      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
      "size": 85528150
    }
  ],
  "schemaVersion": 2
}
```

The manifest containes 2 parts, the `config` file and the `layers` list.

The `config` file is also located in `blobs/sha256` and contains all the info required for running the container such
as the cmd, env variables, exposed ports, mounted volumes etc.

The `layers` list is a list of layers (blobs) for which each layer contains the diff from the previous layer in the filesystem.

##### Adding a layer to the manifest

Let's now add a new layer to the image manifest. For simplicity we are just going to add a new file in `/var/`.

For the following steps, let's make sure we are root.
```
sudo su
```

Before making changes to the container filesystem, we need to unpack the [image-spec](https://github.com/opencontainers/image-spec) to a [runtime-spec](https://github.com/opencontainers/runtime-spec/blob/main/spec.md). This can simple be achieved by running:
```
umoci unpack --image fedora-coreos-image-spec:latest fedora-coreos-runtime-spec
```

Now we can make some modification to the `rootfs`.
```
echo "ybettan was here" > fedora-coreos-runtime-spec/rootfs/var/ybettan.txt
```

And repack the new runtime-spec into a new image-spec overriding the `latest` tag.
Note: we can also `repack` into a new tag but then we will need to modify the `coreos-assembler` to pick that new tag, therefore, overriding the `latest` tag seems to be the simplest approach here.
```
umoci repack --image fedora-coreos-image-spec:latest fedora-coreos-runtime-spec
rm -rf fedora-coreos-runtime-spec
```

Now we need to go back to the `builder` user (in the `cosa` container) for the rest of the flow to work.
```
Ctrl-D
```

All we have left now is to re-compress the image-spec and override the `.ociarchive`.
```
cd fedora-coreos-image-spec
tar -cvf ../builds/latest/x86_64/fedora-coreos-<...>-ostree.x86_64.ociarchive *
cd ../
rm -rf fedora-coreos-image-spec
```

All we need to do at this point is to re-generate the ISO, run it in Qemu and check the `/var` to see if our file is there.
We will need to `--force` the build because the assembler doesn't know that the oci was overwritten.
```
cosa buildextend-live --fast --force
```

### Test the ISO

```
cosa run --qemu-iso builds/latest/x86_64/fedora-coreos-<...>-live.x86_64.iso
```

This invokes QEMU on the image in `builds/latest`.
It uses `-snapshot`, so any changes are thrown away after you exit qemu.
To exit, type `Ctrl-a x`. For more options, type `Ctrl-a ?`.

[go to source](https://github.com/coreos/coreos-assembler/blob/main/docs/building-fcos.md#running)
