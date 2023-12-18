#!/bin/bash

dnf install -y \
    kernel-devel-${KERNEL_VERSION}.rpm \
    kernel-modules-core-${KERNEL_VERSION}.rpm \
    kernel-core-${KERNEL_VERSION}.rpm \
    kernel-${KERNEL_VERSION}.rpm \
    kernel-modules-${KERNEL_VERSION}.rpm
