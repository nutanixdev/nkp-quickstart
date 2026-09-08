# Nutanix Kubernetes Platform - Quickstart Guide

## TL;DR

Steps to install all the required CLIs (nkp, kubectl and helm) to create and manage NKP clusters.

1. Add NKP Rocky Linux image from the Nutanix Support Portal to Prism Central

2. Create a jump host with 2 vCPUs, 8 GB memory, use the Rocky image (update disk to 128 GiB), and the following Cloud-init custom script : [cloud-init](./cloud-init)

3. SSH to `nutanix@<jump host_IP>` (default password: nutanix/4u - unless you modified it in the cloud-init file)

4. Install the NKP CLI with the command: [get-nkp-cli](./get-nkp-cli)

    When prompted, you must use the download link as-is, which is available in the Nutanix portal.

## Table of Contents

1. [Overview](#overview)

2. [Prerequisites Checklist](#prerequisites-checklist)

3. [Deploy Linux jump host](#deploy-linux-jump-host)

4. [Install NKP CLI](#install-nkp-cli)

5. [Create NKP Cluster on Nutanix](#create-nkp-cluster-on-nutanix)
   - [Scripted Automated Deployment](#scripted-automated-deployment-recommended)
   - [Prompt-based Installation](#prompt-based-installation)
   - [CLI Installation](#cli-installation)

## Overview

The NKP CLI is a command-line interface for managing NKP-based workflows. This guide provides a quick and easy way to install the required CLIs (nkp, kubectl and helm) using the Rocky Linux image provided by Nutanix in the [Nutanix Support Portal](https://portal.nutanix.com/page/downloads?product=nkp).

## NKP on Nutanix High level design

Below an example of NKP on Nutanix deployment diagram.
Ip ranges are provided as example.

![NKP HLD](images/nkp-network-diagram.png)

## Prerequisites Checklist

For NKP CLI:

- Internet connectivity
- Add NKP Node OS Image Rocky Linux to Prism Central. **DO NOT CHANGE** the auto-populated image name

    ![Add NKP Rocky OS image](./images/add_nkp_rocky_os_image.png)

For NKP cluster creation:

- The target cluster must be running **AOS 7.3** and **Prism Central (PC) 7.3** or newer. [Check the Nutanix support portal to align NKP, AOS, and PC versions.](https://portal.nutanix.com/page/compatibility-interoperability-matrix/nkp/interoperability)
- **DHCP/IPAM** is required
- IP Addresses (must be reachable to jump host)
  - Static IP address for the control plane VIP
  - One or more IP addresses for the NKP dashboard and load balancing service

## Deploy Linux jump host

1. Connect to Prism Central

2. Create a virtual machine

    - Name: nkp-jump host
    - vCPUs: 4
    - Memory: 8
    - Disk: Clone from Image (select the Rocky Linux you previously uploaded)
    - Disk Capacity: 128 (default is 20)
    - Guest Customization: Cloud-init (Linux)
    - Custom Script: [cloud-init](./cloud-init)

3. Power on the virtual machine

## Install NKP CLI

1. Connect to your jump host using SSH (default password: nutanix/4u)

    ```shell
    ssh nutanix@<jump host_IP>
    ```

2. git clone this repo

    ```shell
    git clone https://github.com/nutanixdev/nkp-quickstart.git
    ```

3. Install the NKP CLI with the command: [get-nkp-cli](./get-nkp-cli)

    ```shell
    cd nkp-quickstart && ./get-nkp-cli
    ```

    When prompted, you must use the download link as-is, which is available in the Nutanix portal.

    ![NKP CLI downloadable link](./images/nkp_cli_link.png)

## Create NKP cluster on Nutanix

Before creating a cluster, ensure you meet the prerequisites:

- Static IP address for the control plane VIP (must be outside of IPAM scope)
- One or more IP addresses for the NKP dashboard and load-balancing service (must be outside of IPAM scope)
- IP addresses must be in the same subnet as the virtual machines
- Access to the Nutanix Support Portal to download the NKP Bundle

![NKP Bundle](./images/bundle.png)

Choose one of the following installation methods based on your needs:

- [Scripted Automated Deployment](#scripted-automated-deployment-recommended)
- [Prompt-based Installation](#prompt-based-installation)
- [CLI Installation](#cli-installation)

### Scripted Automated Deployment (Recommended)

This is the guided deployment path for the jump host created from the repository's [cloud-init](./cloud-init) configuration. Run it from the cloned repository:

```shell
./nkpDeploy.sh
```

The application runs directly in the terminal with a full-screen, purple-themed interface. It does not require a separate TUI framework. Arrow keys and Enter are used for selections; text fields, masked password input, and the final Y/N confirmation are handled inside the same bordered interface. Use `Ctrl-C` to exit.

#### What happens during a run

1. **Local preflight:** Verifies the required command-line tools, checks Docker/Podman and cgroup configuration, tests outbound access to the Nutanix portal, discovers or downloads the NKP bundle, extracts it, and installs the bundled `nkp` and `kubectl` binaries.

2. **Prism Central login:** Collects the Prism Central IPv4 endpoint, username, and masked password. The endpoint and username are saved immediately to `nkpDeploy_defaults.json` so they remain available after a later failed attempt. The password is never written to disk.

3. **API-backed selections:** Uses Prism Central v4 APIs to populate selectors for the AHV cluster, network, storage container, and Rocky VM image. The selected network's CIDR is used to validate the remaining network inputs.

4. **Network and sizing inputs:** Requests the cluster name, control-plane VIP, and load-balancer start address using only the editable host portion of the selected network. You then select the number of load-balancer IPs; the end address is calculated automatically. Control-plane replicas are limited to `1`, `3`, or `5`, and worker replicas to `1` through `10`.

5. **Compatibility checks:** Compares the NKP bundle version, detected Prism Central and AOS versions, and Kubernetes version embedded in the selected Rocky image with the rules in [`nkp_compatibility.json`](./nkp_compatibility.json). A release can list more than one compatible PC/AOS row and supports the current Kubernetes minor version plus one version back where applicable.

6. **Final review and deployment:** Displays a terminal-sized deployment summary and waits for an explicit `Y` or `N` before loading bootstrap images and running `nkp create cluster`.

#### NKP bundle download

The script first looks for a standard NKP bundle that is already present or extracted in the current directory. If it cannot find one, it asks for the **full download URL** from the Nutanix Support Portal.

In the portal, open the download page for the NKP release you want, locate the **standard NKP Bundle**, and copy the download link itself. Paste that complete URL into the prompt exactly as provided, including any query string or temporary access parameters. Do not paste the portal page URL, the NKP CLI link, or the Air-Gapped Bundle link. The filename must resolve to the normal `nkp-bundle_v*.tar.gz` format; the script rejects air-gapped bundles.

#### Inputs loaded from Prism Central

| Input | How it is supplied |
| ----- | ------------------ |
| Prism Central endpoint and username | Entered once and retained in `nkpDeploy_defaults.json` |
| Prism Central password | Entered for each run; never saved |
| AHV cluster | Selected from the Prism Central v4 cluster API |
| Network | Selected from the v4 subnet API; CIDR is used for validation and host-prefix prompts |
| Storage container | Selected from the v4 storage-container API |
| VM image | Selected from Rocky images returned by Prism Central; the Kubernetes version is extracted from its name |
| Control-plane VIP and load-balancer range | Host portion entered against the selected network; load-balancer end address is calculated |
| Control-plane and worker replicas | Selected from bounded options |

The deployment typically takes 45–60 minutes. Once it completes, configure the generated kubeconfig and view the dashboard details:

```shell
export KUBECONFIG=$(pwd)/<cluster_name>.conf
nkp get dashboard
```

#### Compatibility data

The deployment workflow reads release compatibility rules from [`nkp_compatibility.json`](./nkp_compatibility.json). Each release entry has exactly four fields:

- `nkp_version` — matched to the `vX.Y.Z` version in the NKP bundle filename
- `aos_min_version` — minimum AOS versions returned by Prism Central
- `prism_central_min_version` — matching Prism Central minimum versions returned by Prism Central
- `nkp_supported_version` — Kubernetes minor versions supported by the selected NKP Rocky image

For releases with multiple PC/AOS compatibility rows, the AOS and Prism Central arrays are positionally aligned. Update this file as new NKP releases are added or compatibility requirements change.

---

### Prompt-based Installation

This installation method provides an interactive deployment experience with less control over cluster configuration. The NKP cluster will be created with three control plane nodes and four worker nodes (default sizing).

**Use this method if:**

- You want a quick proof-of-concept deployment
- Default cluster sizing works for your use case
- You prefer interactive prompts over pre-configuration

We recommend starting a tmux session in case your ssh connection is at risk of disconnection (like laptop going into sleep mode) as the process can take some time based on several parameters (like download speed).

```shell
nkp create cluster nutanix
```

---

### CLI Installation

This installation method lets you fully customize your cluster configuration. The following commands create a cluster with one control plane node and three worker nodes.

**Use this method if:**

- You need non-standard cluster sizing
- You want to fine-tune every cluster parameter
- You're deploying multiple cluster variations
- You need full control and repeatability via configuration files

1. Before running the following command in your jump host VM, update the values with your environment: [nkp-env](./nkp-env)

2. The next command will start the installation process of an NKP management cluster: [nkp-create-cluster](./nkp-create-mgmt-cluster.sh)

---

## Comparison: Which Method Should I Use?

| Factor | Scripted | Prompt-Based | CLI |
| ------ | -------- | ------------ | --- |
| **Ease of Use** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐ |
| **Customization** | ⭐⭐⭐ | ⭐⭐ | ⭐⭐⭐⭐⭐ |
| **Version Validation** | Automatic | Manual | Manual |
| **Input Validation** | Comprehensive | Basic | None |
| **Time to Deploy** | 5-10 min setup | 10-15 min setup | Variable |
| **Best For** | New users, POCs | Quick tests | Advanced/Production |
| **Typical Use Case** | First deployment | Learning | Automation |

---

## Support and Disclaimer

These code samples are intended as standalone examples. Please be aware that all public code samples provided by Nutanix are unofficial in nature, are provided as examples only, are unsupported, and will need to be heavily scrutinized and potentially modified before they can be used in a production environment. All such code samples are provided on an as-is basis, and Nutanix expressly disclaims all warranties, express or implied. All code samples are © Nutanix, Inc., and are provided as-is under the MIT license (<https://opensource.org/licenses/MIT>).
