# Issue #1 — ArgoCD install fails under `kubectl apply` (client-side)

**Status:** ✅ RESOLVED 2026-06-10 — install healthy after `--server-side --force-conflicts`; all 6 deployments Available
**Opened:** 2026-06-10
**Environment:** kind cluster `gitops-demo`, macOS (Mahesh's MacBook Pro), ArgoCD stable install manifest
**Command that failed:** `kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml`

---

## Symptom 1 — CRD annotation too large

```
The CustomResourceDefinition "applicationsets.argoproj.io" is invalid:
metadata.annotations: Too long: may not be more than 262144 bytes
```

**Root cause:** client-side `kubectl apply` stores the entire object in the
`kubectl.kubernetes.io/last-applied-configuration` annotation so it can
3-way-diff later. The ApplicationSet CRD is larger than the 256KB (262144-byte)
annotation limit, so the API server rejects it. The CRD isn't broken — the
*apply bookkeeping* doesn't fit.

**Fix:** use **server-side apply** — the API server tracks field ownership in
`metadata.managedFields` instead of an annotation; no size limit applies:

```bash
kubectl apply -n argocd --server-side -f .../install.yaml
```

## Symptom 2 — field-manager conflict on retry

Full error output (verbatim):

```
Apply failed with 1 conflict: conflict with "kubectl-client-side-apply" using networking.k8s.io/v1: .spec.ingress
Please review the fields above--they currently have other managers. Here
are the ways you can resolve this warning:
* If you intend to manage all of these fields, please re-run the apply
  command with the `--force-conflicts` flag.
* If you do not intend to manage all of the fields, please edit your
  manifest to remove references to the fields that should keep their
  current managers.
* You may co-own fields by updating your manifest to match the existing
  value; in this case, you'll become the manager if the other manager(s)
  stop managing the field (remove it from their configuration).
See https://kubernetes.io/docs/reference/using-api/server-side-apply/#conflicts
```

**Root cause:** the FIRST (client-side) apply partially succeeded before dying
on the CRD — a NetworkPolicy's `.spec.ingress` got created with field manager
`kubectl-client-side-apply`. The retry used a different manager
(`kubectl` server-side), and SSA refuses to overwrite fields owned by another
manager without explicit consent. Working as designed — conflict detection is
the SSA feature.

**Fix:** since both "managers" are us applying the same upstream manifest,
take ownership:

```bash
kubectl apply -n argocd --server-side --force-conflicts -f .../install.yaml
```

`--force-conflicts` is safe HERE (same human, same manifest). It is NOT a
default habit — in shared clusters a conflict usually means a controller or
teammate genuinely owns that field.

---

## Fix log (chronological)

| When | Action | Result |
|---|---|---|
| 2026-06-10 | Initial `kubectl apply` (client-side) of ArgoCD install manifest | ❌ CRD annotation >256KB; partial apply (some objects created) |
| 2026-06-10 | Retry with `--server-side` | ❌ SSA conflict: `.spec.ingress` owned by `kubectl-client-side-apply` (leftover from partial apply) |
| 2026-06-10 | Retry with `--server-side --force-conflicts` + `kubectl -n argocd wait deploy --all --for=condition=Available` | ✅ SUCCESS — condition met on all 6 deployments: applicationset-controller, dex-server, notifications-controller, redis, repo-server, server (application-controller runs as a StatefulSet, not covered by `wait deploy`) |
| 2026-06-10 | `run-demo.sh` step 3/5 and README install command updated to use `--server-side` (with explanatory comment) so the issue can't recur from a clean run | ✅ Done |

**Verification (2026-06-10):** `kubectl -n argocd wait deploy --all
--for=condition=Available --timeout=300s` → condition met on all 6
deployments. Issue closed. One nuance worth knowing: `argocd-application-controller`
is a StatefulSet, so it's not in the `wait deploy` output — verify it
separately with `kubectl -n argocd get sts` if anything acts up later.

---

## Why this issue is worth keeping

Installing ArgoCD surfaced both classic server-side-apply failure modes in one
session — the 256KB last-applied annotation limit on the ApplicationSet CRD,
then the field-manager conflict left behind by the partial client-side apply.
SSA's managedFields ownership model explains both. Anyone running
ApplicationSets at scale is likely to hit the same thing, so the verbatim
errors and fixes are logged above for reference.
