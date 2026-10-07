# Documentation

This folder describes what runs on the homelab and how it is configured.

Step-by-step setup, configuration, and test procedures live in [setup-and-testing/](setup-and-testing/README.md).

## Contents

| Area | Description |
|---|---|
| [architecture/](architecture/system-architecture.md) | Overall system design and VM layout |
| [hardware/](hardware/hardware-specs.md) | Reference hardware specifications |
| [networking/](networking/networking-plan.md) | Network topology, addressing, and reference |
| [security/](security/security-hardening.md) | Security controls currently in place |
| [services/](services/README.md) | Service-by-service description and configuration |
| [monitoring/](monitoring/monitoring-stack.md) | Monitoring stack |
| [backup-strategy/](backup-strategy/storage-and-backup-plan.md) | Backup plan and retention |

## Design Rules

- TrueNAS provides storage only.
- Docker services run on the Ubuntu Docker VM.
- Internet exposure is limited and comes last.
