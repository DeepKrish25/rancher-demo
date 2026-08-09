# Fleet CNPG recovery test (manual EC2 procedure)

This is a separate experiment from the known-good ArgoCD recovery test.
Ownership is intentionally exclusive:

```text
ArgoCD -> demo-pg
Fleet  -> fleet-demo-pg
```

Never point Fleet at `charts/pg/values.yaml`, and never add `demo-pg` to the
Fleet bundle. Do not automate the deletion steps below.

## Prerequisites

Run this only on the EC2 K3s host, not on the desktop. The host needs at least
4 vCPU, 8 GiB RAM (more is preferable), and sufficient disk for K3s, Rancher,
ArgoCD, MinIO, and CNPG. Keep TCP 22 restricted to your administration IP;
allow TCP 80 and 443 to the Rancher hostname. For this lab, a hostname such as
`<EC2-public-IP>.sslip.io` resolves without creating a DNS record. K3s Traefik
must be available, and Helm 3 plus a working `kubectl` context are required.

Rancher requires TLS. The installer uses cert-manager with Rancher-generated
certificates, so the browser will show a certificate warning in this lab. Set a
strong, non-committed bootstrap password before installation.

## Phase 1 — Install Rancher/Fleet

```bash
export RANCHER_HOSTNAME=<EC2-public-IP>.sslip.io
read -r -s -p 'Rancher bootstrap password: ' RANCHER_BOOTSTRAP_PASSWORD; echo
export RANCHER_BOOTSTRAP_PASSWORD
./scripts/08-install-rancher-fleet.sh
```

Fleet is bundled with Rancher; the script waits for its CRDs, controller, and
local-cluster agent. Do not run the script from the local desktop.

## Phase 2 — Verify

```bash
./scripts/09-verify-rancher-fleet.sh
```

## Phase 3 — Deploy `fleet-demo-pg` using Fleet

Commit and push these repository artifacts first. Then, on EC2, apply the one
GitRepo registration manifest manually:

```bash
kubectl apply -f fleet/gitrepo-fleet-demo-pg.yaml
kubectl get gitrepo -n fleet-local fleet-demo-pg -w
```

The GitRepo `paths` entry limits reconciliation to `fleet/fleet-demo-pg`. Its
Helm bundle uses `charts/pg/values-fleet-example.yaml`, whose initial name is
`fleet-demo-pg` and archive identity is also `fleet-demo-pg`.

## Phase 4 — Verify INIT state

Wait for Fleet to report Ready, then verify the initial cluster:

```bash
kubectl get cluster.postgresql.cnpg.io fleet-demo-pg -n default
kubectl get pods -n default -l cnpg.io/cluster=fleet-demo-pg
kubectl get cluster.postgresql.cnpg.io fleet-demo-pg -n default -o jsonpath='{.spec.bootstrap}'; echo
```

## Phase 5 — Create test data and a backup

Manually create recognizable test data in `fleet-demo-pg`, then trigger or wait
for a CNPG backup and confirm it completed. Do not use the `demo-pg` database
or its archive for this phase.

## Phase 6 — Change Git to RECOVERY

Edit only `charts/pg/values-fleet-example.yaml`: set `bootstrap.mode: recovery`.
Keep `bootstrap.recovery.serverName: fleet-demo-pg` and the post-recovery
`backup.serverName: fleet-demo-pg-recovered`. Commit and push, then wait for
Fleet to fetch the revision. Do not change the existing ArgoCD values file.

## Phase 7 — Delete Cluster and PVC

After confirming Git shows recovery, manually delete only the `fleet-demo-pg`
CNPG Cluster and its PVC(s). Verify every command's target before executing it.
These destructive commands are intentionally not included here.

## Phase 8 — Allow Fleet to recreate the Cluster

Observe the GitRepo/BundleDeployment status and wait for CNPG to become ready.

```bash
kubectl get gitrepo,bundle,bundledeployment -A
kubectl get pods -n default -l cnpg.io/cluster=fleet-demo-pg -w
```

## Phase 9 — Verify restored data

Connect to `fleet-demo-pg` and verify the manually created rows. Also record
the rendered live bootstrap:

```bash
kubectl get cluster.postgresql.cnpg.io fleet-demo-pg -n default -o jsonpath='{.spec.bootstrap}'; echo
```

## Phase 10 — Change Git to EXISTING

Set `bootstrap.mode: existing` in `charts/pg/values-fleet-example.yaml`, then
commit and push. The chart intentionally renders no `spec.bootstrap` in this
mode. Wait for Fleet reconciliation; do not add compare patches or other drift
workarounds.

## Phase 11 — Observe Rancher/Fleet status

Record the following exactly after Fleet has reconciled:

```text
Git desired bootstrap: no explicit spec.bootstrap
Live bootstrap: <kubectl output>
Fleet state: <GitRepo/BundleDeployment state>
Rancher state: <UI status>
Drift/Modified: <exact observed result>
```

Useful commands:

```bash
kubectl get gitrepo -n fleet-local fleet-demo-pg -o yaml
kubectl get bundle,bundledeployment -A
kubectl get cluster.postgresql.cnpg.io fleet-demo-pg -n default -o yaml
```
