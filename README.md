# CNPG + GitOps Drift Demo (minikube + ArgoCD)

Reproduces the Rancher Fleet drift bug (`spec.bootstrap` mismatch after a
CNPG Postgres recovery) using ArgoCD as a stand-in — same diffing
mechanism, same fix (`ignoreDifferences` ≈ Fleet's `comparePatches`).

## 0. Prerequisites (run on your Ubuntu machine, not in any sandbox)

```bash
# Docker (minikube driver)
sudo apt-get update && sudo apt-get install -y docker.io
sudo usermod -aG docker $USER && newgrp docker

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# minikube
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

**Resource note for your hardware (8GB RAM, i5-8250U):** close browsers/IDEs
before starting. The scripts request 4.5GB for the minikube VM, leaving
~3GB for the host. If `minikube start` fails or things get sluggish, spin
up an `t3.large` (2 vCPU / 8GB) or `t3.xlarge` (4 vCPU / 16GB) EC2 instance
running Ubuntu 24.04 instead and run the exact same steps there — nothing
here is laptop-specific.

## 1. Push this repo to your own git provider

```bash
cd cnpg-gitops-drift-demo
git init && git add . && git commit -m "cnpg gitops drift demo"
git remote add origin https://github.com/<you>/cnpg-gitops-drift-demo.git
git push -u origin main
```

Then edit `argocd/application.yaml` and set `spec.source.repoURL` to that
URL.

## 2. Build the environment

```bash
chmod +x scripts/*.sh
./scripts/01-start-cluster.sh      # minikube up
./scripts/02-install-cnpg.sh       # CNPG operator
./scripts/03-install-minio.sh      # stand-in for your GCP bucket
./scripts/05-create-minio-secret.sh
./scripts/04-install-argocd.sh     # ArgoCD, trimmed for low RAM
```

Note the admin password printed at the end of step 4.

## 3. Deploy the app via GitOps (this is your "app bundle")

```bash
kubectl apply -f argocd/application.yaml
kubectl get application demo-pg -n argocd -w
```

Wait until `SYNC STATUS = Synced` and `HEALTH STATUS = Healthy`. Confirm
the Postgres pod is up:

```bash
kubectl get pods -n default -l cnpg.io/cluster=demo-pg
```

This is your baseline — equivalent to `infra-apps-dev-4956` freshly
deployed via `bootstrap.initdb`.

## 4. Reproduce the drift bug

```bash
./scripts/06-reproduce-drift.sh
```

This walks through, pausing for you to inspect at each stage:
1. Confirm live state == git state (`initdb`)
2. Pause the bundle (disable ArgoCD auto-sync)
3. Delete the CNPG Cluster
4. Apply the manual recovery YAML (`manual/manual-restore-cluster.yaml`,
   using `bootstrap.recovery`) and wait for it to go healthy
5. Unpause the bundle (re-enable auto-sync)
6. Show the resulting `OutOfSync` / drift status

At this point `kubectl get application demo-pg -n argocd -o yaml` will
show `spec.bootstrap` as a live diff — reproducing exactly what you're
seeing in Rancher, because git still says `initdb` while the live Cluster
object is running under `recovery`.

## 5. Apply the fix

```bash
./scripts/07-apply-fix.sh
```

This tells you to uncomment `ignoreDifferences` in
`argocd/application.yaml`, commit/push it, then re-applies and verifies
the app goes back to `Synced` / `Healthy` — permanently, regardless of
which bootstrap mode is live. This is the direct equivalent of adding
`diff.comparePatches` to `fleet.yaml` for the `Cluster` CR.

## 6. (Optional) Demonstrate the git-driven restore

Instead of the manual `kubectl apply` in step 4, you can restore purely
through git — proving out the architecture recommended for your real
Rancher setup:

```bash
# Point the SAME Application at the recovery values for this one cluster
# (In Fleet this is targetCustomizations; in ArgoCD it's a values file
# override or an ApplicationSet generator per-cluster — NOT a second
# Application/bundle targeting the same object.)
kubectl delete cluster.postgresql.cnpg.io demo-pg -n default

# simulate the "per-cluster override committed to git" by pointing
# helm at the recovery values file:
helm template charts/pg -f charts/pg/values-recovery-example.yaml | kubectl apply -f -

kubectl wait --for=condition=Ready pod -l cnpg.io/cluster=demo-pg -n default --timeout=180s
kubectl get application demo-pg -n argocd -o jsonpath='{.status.sync.status}{"\n"}'
```

With `ignoreDifferences` already in place, this stays `Synced` even
though the live object now runs `recovery` and git's default
`values.yaml` still says `initdb` — because there's exactly one
bundle owning the object, and the field that flaps is explicitly ignored.

## Files

```
charts/pg/                        Helm chart (mirrors your real cluster.yaml)
  templates/cluster.yaml          CNPG Cluster — the bootstrap conditional lives here
  templates/scheduledbackup.yaml  Backups resume automatically post-restore
  values.yaml                     Default committed state (initdb)
  values-recovery-example.yaml    Per-cluster override example (recovery)
argocd/application.yaml           The "app bundle" — ignoreDifferences fix lives here
manual/manual-restore-cluster.yaml  Mimics your CURRENT manual restore step
manual/minio-bucket-job.yaml      Creates the pg-backups bucket (stand-in for GCP)
scripts/01-07-*.sh                Numbered, run-in-order setup + demo scripts
```

## Mapping back to Fleet/Rancher

| This demo (ArgoCD)                          | Your real setup (Fleet/Rancher)          |
|----------------------------------------------|-------------------------------------------|
| `Application`                                 | Fleet `Bundle` / `GitRepo`               |
| `spec.syncPolicy.automated` on/off             | Pause/unpause bundle                      |
| `spec.ignoreDifferences[].jsonPointers`        | `fleet.yaml` `diff.comparePatches[].jsonPointers` |
| MinIO                                          | GCS bucket                                |
| Second `Application` targeting same object = conflict | Second `Bundle` targeting same cluster/object = conflict (your open question) |
