# Nutanix Kubernetes Platform - Quickstart Guide

## TL;DR

Steps to install all the required CLIs (nkp, kubectl and helm) to create and manage NKP clusters.

1. Add NKP Rocky Linux image from the Nutanix Support Portal to Prism Central

1. Create a jump host with 2 vCPUs, 4 GB memory, use the Rocky image (update disk to 128 GiB), and the following Cloud-init custom script

    ```yaml
    #cloud-config
    ssh_pwauth: true
    chpasswd:
      expire: false
      users:
      - name: nutanix
        password: nutanix/4u # Recommended to change the password or update the script to use SSH keys
        type: text
    bootcmd:
    - mkdir -p /etc/docker
    write_files:
    - content: |
        {
            "insecure-registries": ["registry.nutanixdemo.com"]
        }
      path: /etc/docker/daemon.json
    runcmd:
    - '[ ! -f "/etc/yum.repos.d/nutanix_rocky9.repo" ] || mv -f /etc/yum.repos.d/nutanix_rocky9.repo /etc/yum.repos.d/nutanix_rocky9.repo.disabled'
    - dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
    - dnf -y install docker-ce docker-ce-cli containerd.io
    - systemctl --now enable docker
    - usermod -aG docker nutanix
    - 'curl -Lo /usr/local/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl'
    - chmod +x /usr/local/bin/kubectl
    - 'curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash'
    - eject
    - 'wall "If you are seeing this message, please reconnect your SSH session. Otherwise, the NKP CLI installation process may fail."'
    final_message: "The machine is ready after $UPTIME seconds. Go ahead and install the NKP CLI using: $ curl -sL https://raw.githubusercontent.com/nutanixdev/nkp-quickstart/main/scripts/get-nkp-cli | bash"
    ```

1. SSH to `nutanix@<jump host_IP>` (default password: nutanix/4u)

1. Install the NKP CLI with the command:

    ```shell
    curl -fsSL https://raw.githubusercontent.com/nutanixdev/nkp-quickstart/main/scripts/get-nkp-cli | bash
    ```

    When prompted, you must use the download link as-is, which is available in the Nutanix portal.

## Table of Contents

1. [Overview](#overview)

1. [Prerequisites Checklist](#prerequisites-checklist)

1. [Deploy Linux jump host](#deploy-linux-jump-host)

1. [Install NKP CLI](#install-nkp-cli)

1. [(Optional) Create NKP Cluster on Nutanix](#optional-create-nkp-cluster-on-nutanix)

## Overview

The NKP CLI is a command-line interface for managing NKP-based workflows. This guide provides a quick and easy way to install the required CLIs (nkp, kubectl and helm) using the Rocky Linux image provided by Nutanix in the [Nutanix Support Portal](https://portal.nutanix.com/page/downloads?product=nkp).

## Prerequisites Checklist

For NKP CLI:

- Internet connectivity
- Add NKP Rocky Linux to Prism Central. **DO NOT CHANGE** the auto-populated image name

    <details>
    <summary>click to view example</summary>
    <IMG src="./images/add_nkp_rocky_os_image.png" atl="Add NKP Rocky OS image" />
    </details>

(Optional) For NKP cluster creation:

- Static IP address for the control plane VIP
- One or more IP addresses for the NKP dashboard and load balancing service

## Deploy Linux jump host

1. Connect to Prism Central

1. Create a virtual machine

    - Name: nkp-jump host
    - vCPUs: 2
    - Memory: 4
    - Disk: Clone from Image (select the Rocky Linux you previously uploaded)
    - Disk Capacity: 128 (default is 20)
    - Guest Customization: Cloud-init (Linux)
    - Custom Script:

        ```yaml
        #cloud-config
        ssh_pwauth: true
        chpasswd:
          expire: false
          users:
          - name: nutanix
            password: nutanix/4u # Recommended to change the password or update the script to use SSH keys
            type: text
        bootcmd:
        - mkdir -p /etc/docker
        write_files:
        - content: |
            {
                "insecure-registries": ["registry.nutanixdemo.com"]
            }
          path: /etc/docker/daemon.json
        runcmd:
        - '[ ! -f "/etc/yum.repos.d/nutanix_rocky9.repo" ] || mv -f /etc/yum.repos.d/nutanix_rocky9.repo /etc/yum.repos.d/nutanix_rocky9.repo.disabled'
        - dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
        - dnf -y install docker-ce docker-ce-cli containerd.io
        - systemctl --now enable docker
        - usermod -aG docker nutanix
        - 'curl -Lo /usr/local/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl'
        - chmod +x /usr/local/bin/kubectl
        - 'curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash'
        - eject
        - 'wall "If you are seeing this message, please reconnect your SSH session. Otherwise, the NKP CLI installation process may fail."'
        final_message: "The machine is ready after $UPTIME seconds. Go ahead and install the NKP CLI using: $ curl -sL https://raw.githubusercontent.com/nutanixdev/nkp-quickstart/main/scripts/get-nkp-cli | bash"
        ```

    <details>
    <summary>click to view example</summary>
    <IMG src="./images/create_vm_summary.png" atl="Create VM summary" />
    </details>

1. Power on the virtual machine

## Install NKP CLI

1. Connect to your jump host using SSH (default password: nutanix/4u)

    ```shell
    ssh nutanix@<jump host_IP>
    ```

1. Install the NKP CLI with the command:

    ```shell
    curl -fsSL https://raw.githubusercontent.com/nutanixdev/nkp-quickstart/main/scripts/get-nkp-cli | bash
    ```

    When prompted, you must use the download link as-is, which is available in the Nutanix portal.

## (Optional) Create NKP cluster on Nutanix

1. Before you start, ensure you meet the prerequisites:

    - Static IP address for the control plane VIP
    - One or more IP addresses for the NKP dashboard and load-balancing service

    Note: The IP addresses must be in the same subnet as the virtual machines.

1. Choose one of the following two installation methods:

    - **Prompt-based installation**. Use this method when the Internet connection for the NKP cluster isn’t shared with more users.
    - **CLI installation**. Use this method when the Internet connection for the NKP cluster is shared between many users.

### Prompt-based installation

This installation method gives less control on the cluster configuration. For example, the NKP cluster will be created with three control plane nodes and four worker nodes.

```shell
nkp create cluster nutanix
```

### CLI installation

This installation method lets you fully customize your cluster configuration. The following commands create a cluster with one control plane node and three worker nodes.

1. Before running the following command in your jump host VM, update the values with your environment:

    ```shell
    export NKP_VERSION=2.12.0                                       # NKP version to install
    export CLUSTER_NAME=nkp                                         # NKP cluster name. When using NKP Pro/Ultimate, this name is used to generate the license key
    export NUTANIX_USER=admin                                       # Prism Central username
    export NUTANIX_PASSWORD=''                                      # Keep the password enclosed between single quotes - Ex: 'password'
    export NUTANIX_ENDPOINT=                                        # Prism Central IP address
    export NUTANIX_PORT=9440                                        # Prism Central port (default: 9440)
    export LB_IP_RANGE=                                             # Load balancer IP range - Ex: 10.42.236.204-10.42.236.204
    export CONTROL_PLANE_ENDPOINT_IP=                               # Kubernetes VIP. Must be in the same subnet as the VMs - Ex: 10.42.236.203
    export NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME=nkp-rocky-9.4-release-1.29.6-20240816215147.qcow2 # Update with the NKP Rocky image name
    export NUTANIX_PRISM_ELEMENT_CLUSTER_NAME=                      # Prism Element cluster name - Ex: PHX-POC207
    export NUTANIX_SUBNET_NAME=                                     # Ex: primary
    export NUTANIX_STORAGE_CONTAINER_NAME=SelfServiceContainer      # Change to your preferred Prism storage container
    export REGISTRY_MIRROR_URL=registry.nutanixdemo.com/docker.io   # Required on Nutanix HPOC
    ```

1. The next command will start the installation process of an NKP management cluster:

    ```shell
    nkp create cluster nutanix -c $CLUSTER_NAME \
        --kind-cluster-image $REGISTRY_MIRROR_URL/mesosphere/konvoy-bootstrap:v$NKP_VERSION \
        --endpoint https://$NUTANIX_ENDPOINT:$NUTANIX_PORT \
        --insecure \
        --kubernetes-service-load-balancer-ip-range $LB_IP_RANGE \
        --control-plane-endpoint-ip $CONTROL_PLANE_ENDPOINT_IP \
        --control-plane-vm-image $NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME \
        --control-plane-prism-element-cluster $NUTANIX_PRISM_ELEMENT_CLUSTER_NAME \
        --control-plane-subnets $NUTANIX_SUBNET_NAME \
        --control-plane-replicas 1 \
        --worker-vm-image $NUTANIX_MACHINE_TEMPLATE_IMAGE_NAME \
        --worker-prism-element-cluster $NUTANIX_PRISM_ELEMENT_CLUSTER_NAME \
        --worker-subnets $NUTANIX_SUBNET_NAME \
        --worker-replicas 3 \
        --csi-storage-container $NUTANIX_STORAGE_CONTAINER_NAME \
        --registry-mirror-url http://$REGISTRY_MIRROR_URL \
        --self-managed
    ```

## Support and Disclaimer

These code samples are intended as standalone examples. Please be aware that all public code samples provided by Nutanix are unofficial in nature, are provided as examples only, are unsupported, and will need to be heavily scrutinized and potentially modified before they can be used in a production environment. All such code samples are provided on an as-is basis, and Nutanix expressly disclaims all warranties, express or implied. All code samples are © Nutanix, Inc., and are provided as-is under the MIT license (<https://opensource.org/licenses/MIT>).
