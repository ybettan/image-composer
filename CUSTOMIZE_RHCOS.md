# Table of content
- [Prerequisites](#prerequisites)
- [Set env](#set-env)
- [Build a kernel module](#build-a-kernel-module)
- [Modifying rootFS](#modifying-rootfs)
- [Modifying initramFS](#modifying-rootfs)
- [Building the OS image](#building-the-os-image)
- [Deploy an OCP cluster with custome nodes](#deploy-an-ocp-cluster-with-custome-nodes)
- [Upgrades](#upgrades)
- [Links](#links)

# Prerequisites

NOTE: Installing a day-0 network driver using this method will not be supported using iPXE since networking is required
for pulling the iPXE artifacts.

The CoreOS-assember (`cosa`) is encapsulated in a container but runs as a privileged container
that will create disk images on the host, therefore, all the work is going to be done a VM.

See [coreos-assembler prerequisites](https://github.com/coreos/coreos-assembler/blob/03dd8da933722902b9775c823af68afa5187f774/docs/building-fcos.md#getting-started---prerequisites)

We will also use [skopeo](https://github.com/containers/skopeo) and [umoci](https://github.com/opencontainers/umoci)
to in order to extract the last layer of a container image.
In this demo, we will use skopeo 1.12.0 and umoci 0.4.7

# Set env

FIXME: can we build with FCOS? Is the Registeration of the OS a neccessary step?
### Download the RHCOS ISO for the build env

We will download the ISO
```
curl -L https://developers.redhat.com/content-gateway/file/rhel/9.2/rhel-9.2-x86_64-dvd.iso -o rhel-9.2-x86_64-dvd.iso
```

### Install the virtual machine

Create a VM using virt-manager with
* 4 CPUs
* 4GB of RAM
* 40GB of disk

NOTE:
Make sure to SSH as a user, otherwise we won't be able to `cosa fetch`

### SSH to the machine

Use `virsh net-dhcp-leases default` in order to get the VM IP and then we can SSH to it.

```
ssh <username>@<ip>
```

### Registring the machine to Redhat to get RPM access

To get dnf working, you'll need to register with your RH account during kickstart
or after deployment with subscription-manager register. This can also be done
via the setting in the VM GUI (in the `About` section).

Login has the form of `ybettan@redhat.com` and the password is the RedHat password (not Kerberos).

We can also do it from terminal using
```
subscription-manager register
subscription-manager list
```

NOTE: If the connection is hanging, try connecting to SSO before running the command again.

### Install the Redhat CA

***We will also need to install the RedHat CA to the machine.***

### Create working directory

```
podman pull quay.io/coreos-assembler/coreos-assembler
```

The coreos-assmebler needs a working directory (same as git does).
```
mkdir rhcos
cd rhcos
```

### Defining the cosa alias

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

### Running persistently

At this point, try `cosa shell` to start a shell inside the container.
From here, you can run `cosa ...` to invoke build commands.

### Initializing

We need to make sure to point to the RHEL yum repositories and using the CA on the machine
```
export COREOS_ASSEMBLER_ADD_CERTS='y'
export RHCOS_REPO="<...>"
```

Initializing will clone the specified configuration repo, and create various directories/state such as the OSTree repository.

Note:
We might need to enable VPN and added the domain name to `/etc/hosts`.
Try to run the command and add what's needed based on the error.

```
cosa init --yumrepos "${RHCOS_REPO}" --variant rhel-9.2 --branch release-4.13 https://github.com/openshift/os.git
```

The specified git repository will be cloned into `$PWD/src/config/`.
We can see other directories created such as `builds`, `cache`, `overrides` and `tmp`.

# Build a kernel module

First we need to find what kernel version we are building our ISO with.
```
cosa fetch
export KERNEL_VERSION=$(sudo grep -rnw cache/pkgcache-repo/ -e CONFIG_BUILD_SALT | cut -d"=" -f2 | cut -d'"' -f2)
```

The following steps might need to be done on the host or in a dedicated container such as DTK.

We should also install the kernel packages required for this version
```
sudo dnf install -y \
    kernel-devel-${KERNEL_VERSION} \
    kernel-modules-${KERNEL_VERSION}
```
If they don't exist on the machine, check the yum repos url and download the RPM manually
I have used this command to find the correct repo url
```
cat src/yumrepos/rhel-9.2.repo
```

Now, let us build the kernel module:
```
cd ../
git clone https://github.com/rh-ecosystem-edge/kernel-module-management.git
cd kernel-module-management/ci/kmm-kmod/
KERNEL_SRC_DIR=/lib/modules/${KERNEL_VERSION}/build make all
```

# Modifying rootFS

Go back to the `cosa shell` and make sure to copy the relevant files.

Once build, we will add the `.ko` file to the ISO rootFS
```
cd ../../../rhcos
mkdir -p overrides/rootfs/usr/lib/modules/${KERNEL_VERSION}
cp ../kernel-module-management/ci/kmm-kmod/kmm_ci_a.ko overrides/rootfs/usr/lib/modules/${KERNEL_VERSION}
```

Also, we need to add configuration for loading that `.ko` file at boot time
```
mkdir -p overrides/rootfs/etc/modules-load.d
echo kmm_ci_a > overrides/rootfs/etc/modules-load.d/kmm_ci_a.conf
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

# Modifying initramFS

Go back to the `cosa shell` and make sure to copy the relevant files.

Once build, we will add the `.ko` file to the ISO
```
cd ../../../rhcos
mkdir -p overrides/rootfs/usr/lib/modules/${KERNEL_VERSION}
cp ../kernel-module-management/ci/kmm-kmod/kmm_ci_a.ko overrides/rootfs/usr/lib/modules/${KERNEL_VERSION}
```

Also, we need to add configuration for loading that `.ko` file at initramFS time
```
mkdir -p overrides/rootfs/usr/lib/dracut/dracut.conf.d
echo 'force_drivers+=" kmm_ci_a "' > overrides/rootfs/usr/lib/dracut/dracut.conf.d/dracut.conf
```

We should also run `depmod` to make sure all necessary files are created correctly.
```
sudo depmod -b /usr ${KERNEL_VERSION}
```

```
[coreos-assembler]$ tree overrides/
overrides/
├── rootfs
│   └── usr
│       └── lib
│           ├── dracut
│           │   └── dracut.conf.d
│           │       └── dracut.conf
│           └── modules
│               └── 5.14.0-284.22.1.el9_2.x86_64
│                   └── kmm_ci_a.ko
└── rpm

9 directories, 2 files
```

# Building the OS image

There are usually 2 artifacts needes for customizing RHCOS in OCP
1. The OS image - can be a disk-image or an ISO
2. A conatiner image - this container image is the container representation of the OS image conaining an ostree commit

### Building the container image

Firt we need to build the `.ociarchive` file
```
cosa build container
```

Now we can build the container image out of it
```
sudo podman login quay.io
mkdir rhcos-image-spec
tar -xvf builds/latest/x86_64/rhcos-<...>-ostree.x86_64.ociarchive -C rhcos-image-spec
sudo skopeo copy oci:rhcos-image-spec docker://quay.io/ybettan/rhcos:<version>
```

### Building a raw disk-image

To get a .raw disk-image, used for bare metal nodes we will run
```
cosa build metal
```
This command will also generate the `.ociarchive` file and use it to generate the `.raw` disk-image.

### Building a qcow2 disk-image

To get a .qcow2 disk-image, used for Qemu nodes we will run
```
cosa build qemu
```
This command will also generate the `.ociarchive` file and use it to generate the `.qcow2` disk-image.

### Building an ISO

To get an ISO we first need to build the raw disk-images for metal and metal4k nodes
It will also generate the `.ociarchive` file and use it to build the images.
```
cosa build metal metal4k
cosa buildextend-live
```

##### Test the ISO locally

```
cosa run --qemu-iso builds/latest/x86_64/rhcos-<...>-live.x86_64.iso
```

This invokes QEMU on the image in `builds/latest`.
It uses `-snapshot`, so any changes are thrown away after you exit qemu.
To exit, type `Ctrl-a x`. For more options, type `Ctrl-a ?`.

[go to source](https://github.com/coreos/coreos-assembler/blob/main/docs/building-fcos.md#running)

# Deploy an OCP cluster with custome nodes

### Deploy assisted-service

FIXME: should we use `aicli create onprem` to deploy assisted instead?
We will use [assisted-test-infra](https://github.com/openshift/assisted-test-infra)
to deploy assisted-service locally using [minikube](https://minikube.sigs.k8s.io/docs/)

The default iso type is `minimal-iso` and we built a full-iso so we need to change it.
We should then deploy the service
```
export ISO_IMAGE_TYPE=full-iso
export PULL_SECRET=<pull-secret>
make setup
make run
```

We can validate that `assisted-service` is deployed correctly using
```
oc get pods -n assisted-installer
```

Create a new cluster
```
aicli create cluster -P sno=true -P pull_secret=/root/go/src/github.com/pull-secret custom-rhcos-disk-image
```

### Create the cluster

Now that we have the service running we can use [aicli](https://github.com/karmab/aicli) to interact with it.

Configure `aicli` to point to AI's service IP
```
export AI_URL=http://<AI IP>:<AI port>
```

During the cluster installation MCO will override the node OS based on the `rhel-coreos` container image
in the release payload, since we are running a custom disk image, we need to let MCO know what custom
image we are using to prevent it from overriding our changes.

This is done by adding a `MachineConfig` manifest to the cluster installation.
Make sure to update the `osImageURL` in [machineconfig.yaml](./manifests/machineconfig.yaml) with the
custom container image previously built in [Building the OS image](#building-the-os-image).

Add the `MachineConfig` manifest to the cluster
```
aicli add manifest --dir manifests custom-rhcos-disk-image
aicli list manifests custom-rhcos-disk-image
```

### Nodes discovery

##### Using a custom ISO

FIXME: even better, just boot the VM with the ISO
FIXME: the correct way to do it is to configure assisted-image-service to server an ISO from another web-server isntead of mounting it.
Mount the custom ISO to the `assisted-image-service` pod and make sure to override
`data/rhcos-full-iso-...-x86_64.iso` (keep the same name) with the custom ISO.

Here is a reference to mounting a local directory
```
spec:
  containers:
  - name: ...
    image: ...
    volumeMounts:
    - name: host-mount
      mountPath: /isos
  volumes:
  - name: host-mount
    hostPath:
      path: /home/docker/isos
```

We will also need the `minikube cp` command to copy the ISO to the minikube VM.
```
minikube cp ../image-composer/rhcos-413.92.202307060850-0-live.x86_64.iso /home/docker/isos/rhcos-413.92.202307060850-0-live.x86_64.iso
```

Now, when installation the cluster, assisted-service will serve the derived ISO.
```
make deploy_nodes_with_install NUM_MASTERS=1
```
We can validate that test-infra is indeed using the correct iso by making sure the ISO
file has the same size as our ISO.
```
ls -lh /tmp/test_images/
```

##### Using a custom disk-image

NOTE: The machine must have a least 2 disks, one for booting and one as a target disk for writing RHCOS.

Download the discovery ignition
```
aicli list infraenvs
aicli download discovery-ignition <infraenv>
```
and rename the ignition file to be the same as the VM name `rhcos-disk-image.ign`

FIXME: is it still a requirement after https://github.com/karmab/kcli/commit/91208e02a0b3bc04f5eb1e7c7fcd8f6f77776e63?
IMPORTANT: The ignition must be <vm name>.ign in order for `kcli` to bake it into the VM.

Now we will spawn a VM with a custome disk image to boot

We will use [kcli](https://github.com/karmab/kcli) to boot the machine.
Make sure to update the disk reference in [rhcos-disk-image.yml](./rhcos-disk-image.yml)
```
kcli create plan -f rhcos-disk-image.yml
```

We can get the console and SSH to the machine using
```
kcli console --serial rhcos-disk-image
kcli ssh rhcos-disk-image
```

Now we need to wait for the node to be in the following status
```
status: known
status_info: Host is ready to be installed
```

and the cluster to be in the following status
```
status: ready
status_info: Cluster ready to be installed
```

To get the statuses we can use
```
aicli info <cluster|host> <name>
```

### Cluster installation

Once the cluster is ready to be installed, we can install it using
```
aicli start cluster custom-rhcos-disk-image
```

We can check the installation progresss usin
```
aicli info cluster custom-rhcos-disk-image | yq '.progress'
```

### Cluster validation

Get the kubeconfig
```
aicli download kubeconfig custom-rhcos-disk-image
```

Add the cluster domain and VM IP to `/etc/hosts`
* cluster domain can be found using `cat $KUBECONFIG | grep server`
* VM IP can be found using `kcli list vms`

We can make sure that the `MachineConfig` exist in the cluster
```
root image-composer (devel) $ oc get mc/99-ybettan-external-image
NAME                        GENERATEDBYCONTROLLER   IGNITIONVERSION   AGE
99-ybettan-external-image                                             76m
```

Also we can make sure we have the custom OS image
```
root image-composer (devel) $ oc debug node/rhcos-disk-image

sh-4.4# chroot /host

sh-5.1# rpm-ostree status
State: idle
Deployments:
* ostree-unverified-registry:quay.io/ybettan/rhcos:413.92.202311131205-0
                   Digest: sha256:21641a7551be7e9635f6809cab2b82b68eef5f1331a34a3171238cf38f36b280
                  Version: 413.92.202311131205-0 (2023-11-13T12:07:51Z)

sh-5.1# lsmod | grep kmm
kmm_ci_a               16384  0
```

and if the initramFS in the image was rebuilt in the custom image, we can also make sure that the initramFS image
indeed include our kernel module - to make sure it was loaded at the initramFS stage of the booting process and
not later on
```
sh-5.1# lsinitrd /usr/lib/modules/5.14.0-284.40.1.el9_2.x86_64/initramfs.img | grep kmm_ci_a
-rw-r--r--   1 root     root        67608 Jan  1  1970 usr/lib/modules/5.14.0-284.40.1.el9_2.x86_64/kmm_ci_a.ko
```

When upgrading the kmod to a newer version, we can also check the dmesg
```
sh-5.1# dmesg | grep kmm | grep "Loaded kmm-ci-a"
[    1.621551] Hello, World from V2!. Loaded kmm-ci-a.
```

# Upgrades

### Nodes upgrade

In both cases, custom ISOs and custome disk-image the upgrade process is very easy. All we need to
do is to build a new container image as described in [Building the container image](#building-the-container-image)
and edit the `MachineConfig` in the cluster to point to the new container image.

After the reboot, we can validtae that everything went well on the node
```
root image-composer (devel) $ oc debug node/rhcos-disk-image

sh-4.4# chroot /host

sh-5.1# rpm-ostree status
State: idle
Deployments:
* ostree-unverified-registry:quay.io/ybettan/rhcos:413.92.202311151050-0
                   Digest: sha256:a5e7dc2e5dc65fe5442b8bf351db3d06033cc65a215f4b455059523fdbc18078
                  Version: 413.92.202311151050-0 (2023-11-15T11:08:03Z)

sh-5.1# lsmod | grep kmm
kmm_ci_a               16384  0

sh-5.1# lsinitrd /usr/lib/modules/5.14.0-284.40.1.el9_2.x86_64/initramfs.img | grep kmm_ci_a
-rw-r--r--   1 root     root        67608 Jan  1  1970 usr/lib/modules/5.14.0-284.40.1.el9_2.x86_64/kmm_ci_a.ko

# And indeed the new kmod is loaded
sh-5.1# dmesg | grep kmm | grep "Loaded kmm-ci-a"
[    1.621551] Hello, World from V2!. Loaded kmm-ci-a.
```

### Cluster upgrade

FIXME: add content

# Links

* A [POC](https://gitlab.cee.redhat.com/jmeng/ovs-ci-with-ocp) for modifying OVS and its kernel module with OCP
