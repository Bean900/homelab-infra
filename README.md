# homelab-infra

This repository defines the complete infrastructure of my Kubernetes-based homelab.

It follows a fully declarative GitOps approach using Argo CD and is designed to be reproducible from scratch on a multi-node cluster powered by Talos Linux.

## Goals

- Fully reproducible cluster setup ("from zero to running")
- Strict separation of:
  - Infrastructure (cluster + platform)
  - Applications
- Public repositories without exposing secrets
- Production-grade architecture principles applied to a homelab

## Architecture Overview

This repository is structured into four main layers:

- `bootstrap/`  
  Initial cluster provisioning (Talos Linux + Argo CD installation)

- `clusters/`  
  Entry point for GitOps (root application)

- `platform/`  
  Shared infrastructure components (e.g. ingress, storage, secrets)

- `apps/`  
  Application deployments (Argo CD Applications referencing external repos)

- `projects/`  
  Argo CD access and security boundaries

## Key Principles

- Git is the single source of truth
- No secrets stored in this repository
- Applications are managed in separate repositories
- Deployments are automated via Argo CD

## Bootstrap

The cluster can be initialized using:

```bash
./bootstrap.sh
