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

Backup architecture is intentionally different between environments:

```text
PoC:        CNPG -> MinIO (local S3-compatible mock object storage)
Production: CNPG -> GCS backup bucket (approved Google Cloud identity/IAM access)
```

The production Cluster must use its configured Google Cloud identity, service
account, workload identity, or other approved identity mechanism with the IAM
permissions required for its GCS bucket. Exact production permissions are **to
be confirmed**. The MinIO PoC validated the CNPG/Barman object-storage
recovery workflow; it did not prove production GCS behavior.

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

- `bootstrap.recovery.source: original` successfully recreated the Cluster and
  restored the known rows: `BEFORE-DISASTER`, `RESTORE-ME`, and
  `CRITICAL-DATA`.
- CNPG became healthy with `Ready=True` and `ClusterIsReady`.
- Continuous archiving recovered successfully:
  `ContinuousArchiving=True` / `ContinuousArchivingSuccess`, with new WAL
  files observed in the recovered archive.
- The chart supports `initdb`, `recovery`, and `existing`. The `existing` mode
  intentionally renders no `spec.bootstrap` in the Helm/Git desired manifest.
- Transitioning Git from recovery to existing preserved data and health,
  retained continuous archiving, made the Fleet BundleDeployment `Ready`, and
  removed the Modified/drift report. The live Cluster can retain historical
  bootstrap information; Fleet successfully adopted it without drift.

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

`existing` is essential because it requests no new bootstrap and renders the
Git/Helm desired manifest without `spec.bootstrap`. It does not require or
imply removal of any historical `spec.bootstrap` field from the live CNPG
Cluster. The PoC showed that Fleet can report Ready with no Modified/drift
while the live recovered Cluster retains that historical information.

## 8. Mock DR drill objective

This is not another exploratory PoC. The mock drill must execute the proposed
lifecycle as one controlled procedure in the existing test environment:

```text
healthy -> disaster -> pause/quiesce application -> Git recovery configuration
-> verify Fleet has recovery state -> controlled Cluster deletion
-> Fleet reconciliation -> CNPG recovery -> validate database/data integrity
-> validate continuous archiving -> Git existing configuration
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
5. Verify the pre-delete safety gate before any destructive operation: Fleet
   has fetched the intended recovery commit, its Bundle contains the recovery
   configuration, the target Cluster and namespace are correct, and the
   recovery archive/source is correct. For production-equivalent validation,
   also confirm the intended GCS archive exists, the required recovery
   point/WAL files are available, the recovery configuration references that
   archive, and the recreated Cluster will have required GCS identity/IAM
   access. The operator must explicitly confirm all checks.
6. Perform the approved **MOCK-DR destructive operation** only after the
   safety gate passes. Example placeholder:

   ```bash
   # MOCK-DR ONLY — do not run without approved target, PVC/PV plan, and backup validation
   kubectl delete cluster.postgresql.cnpg.io <cluster-name> -n <namespace>
   ```

7. Reconcile Fleet using the production-approved mechanism. The PoC required
   an explicit `forceSyncGeneration` action after deletion. **Production
   decision required**: test and approve normal Fleet reconciliation (if
   reliable), an explicit supported sync/reconciliation action, or a
   controlled pipeline step; do not assume `forceSyncGeneration` is the final
   production mechanism.
8. Wait for CNPG recovery and record readiness, recovery events, pod status,
   PVC/PV results, and Fleet BundleDeployment status.
9. Validate restored database data, application database connectivity, and
   continuous archiving including new WAL objects in the recovered archive.
   Where production-equivalent validation is possible, confirm the recovered
   Cluster reads the required GCS base backup/WAL archive and resumes writing
   new WAL objects to the intended GCS location.
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
- [ ] Fleet Bundle contains recovery configuration; operator explicitly
      confirms target Cluster, namespace, PVC/PV plan, and recovery archive.
- [ ] Intended GCS archive and required recovery point/WAL files are
      available; recovery configuration references the correct archive.
- [ ] Recreated Cluster has the required Google Cloud identity/service
      account/workload identity and IAM access **to be confirmed** for GCS.
- [ ] Recovery Cluster reports `Ready=True` / `ClusterIsReady`.
- [ ] Expected rows and database integrity checks pass.
- [ ] `ContinuousArchiving=True` / `ContinuousArchivingSuccess` is observed.
- [ ] New WAL objects appear in the recovered archive.
- [ ] New WAL objects are visible in the intended GCS archive where
      production-equivalent validation is possible.
- [ ] Required Kubernetes Secrets, service accounts, workload identity, or
      other GCS identity mechanisms remain available after Cluster recreation.
- [ ] No static cloud credentials are committed to Git.
- [ ] `existing` renders no desired `spec.bootstrap`.
- [ ] BundleDeployment is Ready and Fleet has no Modified/drift state.
- [ ] Application reconnects and passes its agreed smoke tests.

## 11. Acceptance criteria

The drill succeeds only when every checklist item passes, Git contains the
post-recovery `existing` configuration, no undocumented manual corrective
action was required, and evidence is available for review. The documented
Cluster deletion and documented Fleet reconciliation action are intentional
DR procedure steps, not failures.

## 12. Failure / rollback scenarios

Define stop conditions before the drill: recovery failure, excessive recovery
duration, invalid data, Fleet reconciliation failure, CNPG not Ready,
archiving not resuming, GCS access failure, or application connection failure.

For each stop condition, **production decision required**: identify the
incident owner, maximum wait time, evidence to collect, whether the
application remains paused, and the supported recovery option. Do not assume
that reapplying `initdb` is a rollback: it could create an empty database.
The approved fallback must preserve forensic evidence and must not overwrite
the backup archive needed for recovery.

## 13. PVC and storage considerations

The mock drill must explicitly document and test the effects of Cluster
deletion on the CNPG Cluster, PVCs, PVs, StorageClass reclaim policy, and
recovered database storage. This is an explicit mock-drill acceptance area:
determine what happens to the CNPG Cluster, whether PVCs are deleted or
retained, PV and StorageClass reclaim behavior, whether a retained PVC can
interfere with recovery, whether the recovered Cluster creates a new PVC, and
whether recovered storage has the expected capacity and access mode. Do not
assume any production result until it is tested against the actual production
StorageClass and reclaim configuration.

## 14. Secrets and security considerations

Do not place credentials in Git. Inventory and test the availability of backup
credentials, GCS identity/IAM access, application DB credentials, Kubernetes
Secrets, service accounts, workload identity, and GitOps secret references
before deletion and after recovery. Document secret ownership, rotation,
least-privilege access, restoration requirements, and how application
credentials are validated. Redact credentials from evidence, logs, PRs, and
incident tickets.

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
- [ ] GCS access and IAM/workload identity are validated.
- [ ] Recovery archive and WAL availability are validated.
- [ ] PVC/PV/StorageClass behavior and data-retention risks are approved.
- [ ] RPO/RTO and backup restoration point/WAL retention objectives are
      validated.
- [ ] Secret, access-control, audit, and break-glass requirements are approved.
- [ ] Application quiesce/resume and connectivity checks are automated or
      operationally owned.
- [ ] Failure/rollback procedure, communications, and escalation
      responsibilities are approved.
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
- What exact GCS IAM permissions and identity mechanism are approved for CNPG
  access, and how are they validated after Cluster recreation?

## 19. Final recommendation

Adopt the single-owner `initdb -> recovery -> existing` design as the basis
for the mock drill. Do not add drift workarounds or parallel DB owners. Treat
the Cluster deletion/reconciliation operation, GCS access, storage semantics,
secrets, rollback, and application recovery as controlled operational steps
that must be proven before production rollout.

## Current conclusion

The CNPG/Fleet technical solution has been proven in the PoC. The remaining
work is to execute the exact proposed lifecycle as a controlled mock
disaster-recovery drill and validate the operational details
(delete/reconciliation, storage/PVC behavior, secrets, rollback, application
recovery, GCS access, and final Fleet adoption) before production rollout.
