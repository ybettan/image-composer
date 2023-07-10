# image-composer

### Prerequisites

The CoreOS-assember (`cosa`) is encapsulated in a container but runs as a privileged container that will create disk images on the host, therefore, all the work is going to be done a VM.

See [coreos-assembler prerequisites](https://github.com/coreos/coreos-assembler/blob/03dd8da933722902b9775c823af68afa5187f774/docs/building-fcos.md#getting-started---prerequisites)

We will also use [skopeo](https://github.com/containers/skopeo) and [umoci](https://github.com/opencontainers/umoci)
to in order to extract the last layer of a container image.
In this demo, we will use skopeo 1.12.0 and umoci 0.4.7

FIXME: can we build with FCOS? Is the Registeration of the OS a neccessary step?
##### Download the RHCOS ISO for the build env

We will download the ISO
```
curl -L https://developers.redhat.com/content-gateway/file/rhel/9.2/rhel-9.2-x86_64-dvd.iso -o rhel-9.2-x86_64-dvd.iso
```

##### Install the virtual machine

Create a VM using virt-manager with
* 4 CPUs
* 4GB of RAM
* 40GB of disk

### Set up the environment

##### SSH to the machine

Use `virsh net-dhcp-leases default` in order to get the VM IP and then we can SSH to it.

```
ssh <username>@<ip>
```

##### Create working directory

```
podman pull quay.io/coreos-assembler/coreos-assembler
```

The coreos-assmebler needs a working directory (same as git does).
```
mkdir rhcos
cd rhcos
```

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

##### Running persistently

At this point, try `cosa shell` to start a shell inside the container.
From here, you can run `cosa ...` to invoke build commands.

##### Initializing

To get dnf working, you'll need to register with your RH account during kickstart
or after deployment with subscription-manager register. This can also be done
via the setting in the VM GUI (in the `About` section).

Login has the form of `ybettan@redhat.com` and the password is the RedHat password (not Kerberos).

***We will also need to install the RedHat CA to the machine.***

Now we need to make sure to point to the RHEL yum repositories and using the CA on the machine
```
export COREOS_ASSEMBLER_ADD_CERTS='y'
export RHCOS_REPO="<...>"
```

Initializing will clone the specified configuration repo, and create various directories/state such as the OSTree repository.

```
cosa init --yumrepos "${RHCOS_REPO}" --variant rhel-9.2 --branch release-4.13 https://github.com/openshift/os.git
```

The specified git repository will be cloned into `$PWD/src/config/`.
We can see other directories created such as `builds`, `cache`, `overrides` and `tmp`.

### Generate a falvored RHCOS ISO by changing the config repo

FIXME: the current instructions are only modifying the rootFS but we also need to modify the initramFS in some cases
##### Add overrides to the config repo

First we need to find what kernel version we are building our ISO with.
```
cosa fetch
export KERNEL_VERSION=$(sudo grep -rnw cache/pkgcache-repo/ -e CONFIG_BUILD_SALT | cut -d"=" -f2 | cut -d'"' -f2)
```

The following steps might need to be done on the host or in a dedicated container such as DTK.

We should also install the kernel packages required for this version
```
sudo dnf install -y kernel-devel-${KERNEL_VERSION}
sudo dnf install -y kernel-modules-${KERNEL_VERSION}
```
If they don't exist on the machine, check the yum repos url and download the RPM manually
I have used this command to find the correct repo url
```
cat src/config/manifest-rhel-9.2.yaml | grep repo | grep server-ose
```

Now, let us build the kernel module:
```
cd ../
git clone https://github.com/rh-ecosystem-edge/kernel-module-management.git
cd kernel-module-management/ci/kmm-kmod/
KERNEL_SRC_DIR=/lib/modules/${KERNEL_VERSION}/build make all
```

Go back to the `cosa shell` and make sure to copy the relevant files.

Once build, we will add the `.ko` file to the ISO rootFS
```
cd ../../../fcos
mkdir -p overrides/rootfs/usr/lib/modules/${KERNEL_VERSION}
cp ../kernel-module-management/ci/kmm-kmod/kmm_ci_a.ko overrides/rootfs/usr/lib/modules/${KERNEL_VERSION}
```

Also, we need to add configuration for loading that `.ko` file at boot time
```
mkdir -p overrides/rootfs/etc/modules-load.d
echo kmm_ci_a > overrides/rootfs//etc/modules-load.d/kmm_ci_a.conf
```

We should also run `depmod` to make sure all necessary files are created correctly.
```
sudo depmod -b /usr ${KERNEL_VERSION}
```

```
[coreos-assembler]$ tree overrides/
overrides/
├── rootfs
│   ├── etc
│   │   └── modules-load.d
│   │       └── kmm_ci_a.conf
│   └── usr
│       └── lib
│           └── modules
│               └── 5.14.0-284.22.1.el9_2.x86_64
│                   └── kmm_ci_a.ko
└── rpm

9 directories, 2 files
```

Now we can generate the ISO
```
cosa build metal metal4k
cosa buildextend-live
```

Running a VM with that ISO should load the kernel module at boot. It can be validated
using
```
lsmod | grep kmm_ci_a
```
in the VM.

### Test the ISO

```
cosa run --qemu-iso builds/latest/x86_64/fedora-coreos-<...>-live.x86_64.iso
```

This invokes QEMU on the image in `builds/latest`.
It uses `-snapshot`, so any changes are thrown away after you exit qemu.
To exit, type `Ctrl-a x`. For more options, type `Ctrl-a ?`.

[go to source](https://github.com/coreos/coreos-assembler/blob/main/docs/building-fcos.md#running)

### Running with assisted-test-infra

The default iso type is `minimal-iso` and we built a full-iso so we need to change it.
```
export ISO_IMAGE_TYPE=full-iso
```

Run assisted-service
```
export PULL_SECRET=...
make setup
make run
```

Mount the custom ISO to the `assisted-image-service` pod and make sure to override
`data/rhcos-full-iso-...-x86_64.iso` (keep the same name) with the custom ISO.

Here is a reference to mounting a local directory
```
spec:
  containers:
  - name: ...
    image: ...
    ports:
    - containerPort: 80
    volumeMounts:
      - name: host-mount
        mountPath: /usr/share/nginx/html/static
  volumes:
    - name: host-mount
      hostPath:
        path: /Users/jyee/code/simplest-k8s/host-mount
```

We will also need the `minikube cp` command to copy the ISO to the minikube VM.
```
minikube cp ../image-composer/rhcos-413.92.202307060850-0-live.x86_64.iso /home/docker/isos/rhcos-413.92.202307060850-0-live.x86_64.iso
```

We also need to create a `MachineConfig` manifest to override the image in MCO.
MCO is overriding the node image with the `machine-os-content` from the release image,
therefore, we need to make sure MCO is aware we are overriding the node image.

We need to build the container image first
```
sudo podman login quay.io
tar -xvf builds/latest/x86_64/rhcos-413.92.202307060850-0-ostree.x86_64.ociarchive -C rhcos-image-spec
sudo skopeo copy oci:rhcos-image-spec docker://quay.io/ybettan/rhcos:413.92.202307060850-0
```

Now we need to create the `MachineConfig` manifest and add it to assisted
```
mkdir -p ~/go/src/github.com/assisted-test-infra/custom_manifests/openshift
cp machineconfig.yaml ~/go/src/github.com/assisted-test-infra/custom_manifests/openshift/
export CUSTOM_MANIFESTS_FILES=$(realpath ~/go/src/github.com/assisted-test-infra/custom_manifests)
```

Then we can
```
make deploy_nodes_with_install NUM_MASTERS=1
```

We can validate that test-infra is indeed using the correct iso by making sure the ISO
file has the same size as our ISO.
```
ls -lh /tmp/test_images/
```

Once the cluster installed we can validate that our kernel-module is indeed installed
```
root assisted-test-infra (master) $ oc get nodes
NAME                                   STATUS   ROLES                         AGE   VERSION
test-infra-cluster-2d9248b4-master-0   Ready    control-plane,master,worker   47m   v1.26.6+a7ee68b

root assisted-test-infra (master) $ oc debug node/test-infra-cluster-2d9248b4-master-0
Starting pod/test-infra-cluster-2d9248b4-master-0-debug ...
To use host binaries, run `chroot /host`
Pod IP: 192.168.127.10
If you don't see a command prompt, try pressing enter.

sh-4.4# chroot /host

sh-5.1# rpm-ostree status
State: idle
Deployments:
* ostree-unverified-registry:quay.io/ybettan/rhcos:413.92.202307060850-0
                   Digest: sha256:39c0aaa7baae5799d7eca830f230a486b62712e742aabd466f6ce0e16712a6c9
                  Version: 413.92.202307060850-0 (2023-07-10T08:02:35Z)

sh-5.1# lsmod | grep kmm
kmm_ci_a               16384  0
```
