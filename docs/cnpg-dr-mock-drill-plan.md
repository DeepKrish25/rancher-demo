# CNPG PostgreSQL disaster-recovery mock drill plan

## 1. Purpose

This design and discussion document proposes a controlled mock
disaster-recovery (DR) drill for CNPG PostgreSQL managed through Rancher
Fleet/GitOps. It is intended for Dev, Platform, and Cloud team review before
any production implementation. It does not authorize or execute a DR event.

The technical lifecycle has been proven in a PoC. The remaining objective is
to validate its operational procedure end-to-end in a controlled test
environment.

## 2. Current architecture

```text
Git -> Rancher/Fleet -> Kubernetes/Talos cluster -> applications + CNPG PostgreSQL
```

The normal database manifest creates a CNPG Cluster using `bootstrap.initdb`.
The preferred operating model has one authoritative DB GitOps owner for the
CNPG Cluster throughout its lifecycle. Application resources and DB resources
may be separate *permanent* bundles, but the DB bundle must be the sole owner
of the CNPG Cluster, ScheduledBackup, and DB configuration.

## 3. Current problem

The prior manual DR approach paused the application bundle, deleted the
Cluster, manually applied recovery configuration, validated it, and resumed
Fleet. Normal Git still declared `bootstrap.initdb`, while the restored live
Cluster had been created with `bootstrap.recovery`. When Fleet resumed, that
difference was reported as Modified/drift.

## 4. Root cause

CNPG bootstrap is creation-time configuration, not an in-place recovery
operation. Changing Git from `initdb` to `recovery` does not recover an
already-running Cluster. A new Cluster must be created while the desired state
is recovery.

The original drift was therefore caused by returning to Git desired state
`initdb` after the Cluster had been created through `recovery`.

## 5. PoC findings / what has been proven

The following are **Proven by PoC**:

- The correct CNPG annotation is
  `cnpg.io/skipEmptyWalArchiveCheck: "enabled"`; `"true"` is not correct.
  It was verified from Git source through Helm, Fleet Bundle, Helm release,
  and the live CNPG Cluster.
- `bootstrap.recovery.source: original` successfully recreated the Cluster and
  restored the known rows: `BEFORE-DISASTER`, `RESTORE-ME`, and
  `CRITICAL-DATA`.
- CNPG became healthy with `Ready=True` and `ClusterIsReady`.
- Continuous archiving recovered successfully:
  `ContinuousArchiving=True` / `ContinuousArchivingSuccess`, with new WAL
  files observed in the recovered archive.
- The chart supports `initdb`, `recovery`, and `existing`. The `existing` mode
  intentionally renders no `spec.bootstrap`.
- Transitioning Git from recovery to existing preserved data and health,
  retained continuous archiving, made the Fleet BundleDeployment `Ready`, and
  removed the Modified/drift report. Fleet successfully adopted the recovered
  Cluster.

## 6. Proposed architecture

Do not introduce a temporary or parallel DR Fleet bundle that manages the
same CNPG Cluster as the normal bundle. Two GitOps owners must never compete
for that resource.

The proposed model is a single authoritative DB owner:

```text
DB GitOps bundle: CNPG Cluster, ScheduledBackup, DB configuration
Application bundle: Deployments, Services, Ingress, application resources
```

The first bundle alone owns the CNPG Cluster for normal operation and DR.

## 7. CNPG lifecycle: initdb -> recovery -> existing

```text
NORMAL                 RECOVERY                    POST-RECOVERY
bootstrap.mode=initdb  bootstrap.mode=recovery     bootstrap.mode=existing
        |                       |                           |
        +---- disaster ----------+---- validate recovery -----+
                                                            |
                                             normal GitOps management
```

`existing` is essential because it requests no new bootstrap, removes
`spec.bootstrap` from the desired manifest, lets Fleet manage the already
recovered Cluster, and prevents the original initdb-versus-recovery drift.

## 8. Mock DR drill objective

This is not another exploratory PoC. The mock drill must execute the proposed
lifecycle as one controlled procedure in the existing test environment:

```text
healthy -> disaster -> pause application -> Git recovery -> controlled delete
-> Fleet reconciliation -> CNPG recovery -> validate -> Git existing
-> Fleet adoption/no drift -> resume application -> final validation
```

## 9. Detailed mock DR procedure

All steps below are **to be validated by mock drill**. Do not run them against
production without an approved production runbook and change authorization.

1. Confirm a healthy baseline: application connectivity, CNPG readiness,
   backup completion, continuous archiving, and a known data set.
2. Record Cluster, PVC, PV, StorageClass, backup archive, secret references,
   Fleet GitRepo/BundleDeployment state, and Git revision.
3. Pause application traffic or the application bundle according to the
   approved test procedure. Do not create another DB owner.
4. On a short-lived incident branch, change the DB desired state to
   `bootstrap.mode: recovery`; retain the approved recovery source/archive.
5. Verify Fleet has fetched and rendered the recovery desired state before any
   destructive operation.
6. Perform the approved **MOCK-DR destructive operation** only after explicit
   confirmation of the target Cluster and storage behavior. Example placeholder:

   ```bash
   # MOCK-DR ONLY — do not run without approved target, PVC/PV plan, and backup validation
   kubectl delete cluster.postgresql.cnpg.io <cluster-name> -n <namespace>
   ```

7. Reconcile Fleet using the production-approved mechanism. The PoC manually
   used `forceSyncGeneration` after deletion; **production decision required**:
   determine whether normal reconciliation, a controlled pipeline action, or
   another supported method is the operational mechanism.
8. Wait for CNPG recovery and record readiness, recovery events, pod status,
   PVC/PV results, and Fleet BundleDeployment status.
9. Validate restored database data, application database connectivity, and
   continuous archiving including new WAL objects in the recovered archive.
10. Change the same DB bundle on the incident branch to
    `bootstrap.mode: existing`, then let Fleet reconcile.
11. Verify the desired manifest has no `spec.bootstrap`, the live recovered
    Cluster remains healthy, Fleet reports Ready without Modified/drift, and
    the application can reconnect.
12. Resume the application only after all validation gates pass. Capture final
    evidence and complete incident-branch merge/closure per policy.

## 10. Validation checklist

- [ ] Baseline backup and recoverable data set recorded.
- [ ] Git recovery revision fetched and rendered by Fleet before deletion.
- [ ] Correct target Cluster, namespace, PVC/PV plan, and archive confirmed.
- [ ] Recovery Cluster reports `Ready=True` / `ClusterIsReady`.
- [ ] Expected rows and database integrity checks pass.
- [ ] `ContinuousArchiving=True` / `ContinuousArchivingSuccess` is observed.
- [ ] New WAL objects appear in the recovered archive.
- [ ] `existing` renders no desired `spec.bootstrap`.
- [ ] BundleDeployment is Ready and Fleet has no Modified/drift state.
- [ ] Application reconnects and passes its agreed smoke tests.

## 11. Acceptance criteria

The drill succeeds only when every checklist item passes, Git contains the
post-recovery `existing` configuration, no manual corrective action outside
this documented procedure was required, and evidence is available for review.

## 12. Failure / rollback scenarios

Define stop conditions before the drill: recovery failure, excessive recovery
duration, invalid data, Fleet reconciliation failure, CNPG not Ready,
archiving not resuming, or application connection failure.

For each stop condition, **production decision required**: identify the
incident owner, maximum wait time, evidence to collect, whether the
application remains paused, and the supported recovery option. Do not assume
that reapplying `initdb` is a rollback: it could create an empty database.
The approved fallback must preserve forensic evidence and must not overwrite
the backup archive needed for recovery.

## 13. PVC and storage considerations

The mock drill must explicitly document and test the effects of Cluster
deletion on the CNPG Cluster, PVCs, PVs, StorageClass reclaim policy, and
recovered database storage. Confirm which resources are deleted or retained,
whether manual PVC deletion is required for the intended restore model, and
whether any retained volume could interfere with recovery. Verify capacity,
access modes, snapshots if applicable, and cleanup requirements after the
test. This is a **production decision required** before production use.

## 14. Secrets and security considerations

Do not place credentials in Git. Inventory and test the availability of backup
credentials, MinIO/GCS/S3 credentials, application DB credentials, Kubernetes
Secrets, and GitOps secret references before deletion and after recovery.
Document secret ownership, rotation, least-privilege access, restoration
requirements, and how application credentials are validated. Redact secrets
from evidence, logs, PRs, and incident tickets.

## 15. Git branch / PR strategy

Use a short-lived incident branch, for example `recovery/INC-XXXX`, for the
temporary recovery and existing desired states. Do not create a permanent DR
branch. Review and approve the recovery transition before the destructive
operation, then merge the final `existing` state into the normal branch under
the organization’s branching policy. Define the required reviewers, change
record, audit evidence, and emergency approval path before production.

## 16. Fleet ownership rules

- One permanent DB bundle is the only owner of a given CNPG Cluster.
- An application bundle must not render, patch, or adopt that Cluster.
- A temporary DR bundle must not take ownership during an incident.
- Recovery and existing are state transitions of the same authoritative DB
  owner, not transfers between bundles or controllers.

## 17. Production readiness checklist

- [ ] Mock drill acceptance criteria passed and evidence reviewed.
- [ ] Delete/reconciliation mechanism is approved and tested.
- [ ] PVC/PV/StorageClass behavior and data-retention risks are approved.
- [ ] Backup restoration point and WAL retention objectives meet RPO/RTO.
- [ ] Secret, access-control, audit, and break-glass requirements are approved.
- [ ] Application quiesce/resume and connectivity checks are automated or
      operationally owned.
- [ ] Failure paths, communications, and escalation responsibilities are
      documented.
- [ ] DB ownership boundaries are enforced in Fleet configuration and review.

## 18. Open questions / items requiring team discussion

- What exact controlled action should trigger Fleet reconciliation after
  deletion: normal polling, pipeline action, or a supported explicit sync?
- Which PVC/PV resources are deleted, retained, or recreated for each storage
  class and reclaim policy?
- What are the approved RPO, RTO, recovery timeout, and stop conditions?
- How is application write traffic quiesced and later safely resumed?
- Which data-integrity, schema, and application smoke tests constitute valid
  recovery?
- Who can approve the destructive operation and the transition to `existing`?
- What evidence, alerting, and audit records are mandatory for a production DR
  event?

## 19. Final recommendation

Adopt the single-owner `initdb -> recovery -> existing` design as the basis
for the mock drill. Do not add drift workarounds or parallel DB owners. Treat
the deletion/reconciliation operation, storage semantics, secrets, rollback,
and application recovery as operational controls that must be proven before
production rollout.

## Current conclusion

The CNPG/Fleet technical solution has been proven in the PoC. The remaining
work is to execute the exact proposed lifecycle as a controlled mock
disaster-recovery drill and validate the operational details
(delete/reconciliation, storage/PVC behavior, secrets, rollback, application
recovery, and final Fleet adoption) before production rollout.
