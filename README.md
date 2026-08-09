# CNPG GitOps recovery-state demo (K3s + ArgoCD)

This repository prepares a disposable Ubuntu EC2/K3s environment for a
CloudNativePG (CNPG) GitOps recovery experiment. It intentionally keeps one
ArgoCD `Application` (`demo-pg`) and one CNPG `Cluster` (`demo-pg`).

The chart supports three committed Helm rendering states:

| `bootstrap.mode` | Rendered CNPG state |
| --- | --- |
| `initdb` | `spec.bootstrap.initdb` |
| `recovery` | `spec.bootstrap.recovery` |
| `existing` | no `spec.bootstrap` |

`existing` is a Helm rendering state for a Cluster that has already
bootstrapped. It is not a CNPG bootstrap method.

## EC2 prerequisites

Use a fresh Ubuntu 22.04 or 24.04 EC2 instance with enough room for K3s,
MinIO, ArgoCD, and PostgreSQL (at least 2 vCPU, 4 GiB RAM, and 20 GiB disk;
8 GiB RAM is more comfortable). Allow SSH from your administration address.
Run these commands as the Ubuntu login user:

```bash
sudo apt-get update
sudo apt-get install -y git curl ca-certificates
git clone https://github.com/DeepKrish25/rancher-demo.git
cd rancher-demo
chmod +x scripts/*.sh

./scripts/01-start-cluster-ec2-k3s.sh
./scripts/02-install-cnpg.sh
./scripts/03-install-minio.sh
./scripts/05-create-minio-secret.sh
./scripts/04-install-argocd.sh
```

The EC2 script is the repository's existing K3s bootstrap; do not run the
Minikube script (`01-start-cluster.sh`) on EC2. The K3s script installs
`kubectl` and Helm when they are not already available.

## Initial GitOps deployment

The committed `charts/pg/values.yaml` defaults to `bootstrap.mode: initdb`.
After the setup scripts complete, deploy the one ArgoCD application:

```bash
kubectl apply -f argocd/application.yaml
kubectl get application demo-pg -n argocd -w
```

When it reports `Synced` and `Healthy`, confirm the initial cluster:

```bash
kubectl get cluster.postgresql.cnpg.io demo-pg -n default
kubectl get pods -n default -l cnpg.io/cluster=demo-pg
```

## Changing Git state for the manual recovery workflow

Do not run the recovery automatically. Perform the deletion, restore, and
inspection manually. For the Git-driven state changes, update the same chart
values file (or a values file referenced by the same Application), commit and
push the change, then let the existing `demo-pg` Application reconcile it.
Do not create a second Application for this Cluster.

The expected manual checkpoints are:

1. Baseline: Git `initdb`, live `initdb`.
2. Manual recovery drift reproduction: Git `initdb`, live `recovery` — drift
   is expected.
3. Git-driven recovery: Git `recovery`, live `recovery` — no drift expected.
4. Post-recovery: Git `existing`, live has no bootstrap field — no drift
   expected.

The recovery source is configurable at `bootstrap.recovery.source`; it must
match the rendered `externalClusters` entry (the default is `original`).

Useful rendering checks before committing a state:

```bash
helm lint charts/pg
helm template demo-pg charts/pg --set bootstrap.mode=initdb
helm template demo-pg charts/pg --set bootstrap.mode=recovery
helm template demo-pg charts/pg --set bootstrap.mode=existing
```

## Existing drift-workaround demonstration

The manual drift reproduction remains available as
`scripts/06-reproduce-drift.sh`, with its manual restore manifest in
`manual/manual-restore-cluster.yaml`. It intentionally demonstrates the
undesired state where Git says `initdb` but the live Cluster says `recovery`.

`scripts/07-apply-fix.sh` and the commented `ignoreDifferences` block in
`argocd/application.yaml` remain as a comparison to the historical
`ignoreDifferences`/Fleet `comparePatches` workaround. They are disabled by
default and are not the recovery solution used by this chart.

## Separate Rancher/Fleet recovery test

The repository also contains an isolated Fleet experiment. It has strict
ownership boundaries: ArgoCD manages only `demo-pg`; Fleet manages only
`fleet-demo-pg`. The controllers must never manage the same CNPG `Cluster`.
The Fleet values use distinct MinIO archive identities, so this test cannot
overwrite or recover from the existing `demo-pg` backup archive.

Follow the manual EC2-only procedure in
[docs/fleet-recovery-test.md](docs/fleet-recovery-test.md). It includes the
Rancher/Fleet installation and read-only verification scripts, and records the
final desired-versus-live `spec.bootstrap` observation without adding Fleet
drift workarounds.

## Repository layout

```text
scripts/01-start-cluster-ec2-k3s.sh  Existing EC2 K3s bootstrap
scripts/02-install-cnpg.sh           CNPG operator installation
scripts/03-install-minio.sh          MinIO and backup bucket installation
scripts/04-install-argocd.sh         ArgoCD installation
scripts/05-create-minio-secret.sh    Object-store credentials
scripts/06-reproduce-drift.sh        Existing manual drift reproduction
scripts/07-apply-fix.sh              Existing workaround comparison
scripts/08-install-rancher-fleet.sh  Manual EC2 Rancher/Fleet installation
scripts/09-verify-rancher-fleet.sh   Read-only Rancher/Fleet verification
charts/pg/                           CNPG Cluster and ScheduledBackup chart
charts/pg/values-fleet-example.yaml  Isolated Fleet Cluster values
argocd/application.yaml              The single GitOps Application
fleet/                               Fleet bundle and manual GitRepo registration
docs/fleet-recovery-test.md          Fleet recovery test procedure
```
