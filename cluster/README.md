# Cluster-scoped resources

Objects that belong to the cluster itself rather than to the application.

**As of Milestone 7, this directory is managed by Argo CD, not applied by
hand.** `argocd/applications/00-namespaces.yaml`, `30-storageclass.yaml` and
`20-cluster-secrets.yaml` point at the three subdirectories below (each one a
directory-type Application, so a values file can never accidentally be
ingested as a manifest). The `kubectl apply` commands in this file are the
pre-M7 manual procedure — kept here for the bootstrap runbook's T9 cleanup
step and for anyone reading this before Argo CD exists on a fresh cluster, not
as the normal way to apply these anymore.

## `namespaces/`

`sports-store.yaml` and `external-secrets.yaml`. Applied in Argo CD's wave 0 —
before anything that needs to be created inside them.

## `external-secrets/`

`clustersecretstore.yaml` (the AWS Secrets Manager backend, IRSA-authenticated)
plus the two `ExternalSecret`s that replace `k8s/secrets/apply-secrets.sh`'s
manual `kubectl create secret`. See
`argocd/README.md` for the ESO chart install and the password-rotation
runbook (T5) — rotating `MONGO_ROOT_PASSWORD` in Secrets Manager now
propagates into the cluster automatically, which makes the existing "rotate
the Secret without rotating the Mongo user" trap worse, not better.

## `storageclass/gp3.yaml`

Makes `gp3` the cluster's **default** StorageClass.

### Why it is needed

EKS ships a `gp2` StorageClass but does not annotate it as default. A PVC that
omits `storageClassName` — which is what a Helm chart's default persistence
config produces — therefore stays `Pending` indefinitely with:

```
no persistent volumes available for this claim and no storage class is set
```

Found on the Milestone 4 cluster with a throwaway PVC; the same PVC bound
immediately once a default existed.

### Why `ebs.csi.aws.com` rather than reusing gp2

`gp2`'s provisioner is the in-tree `kubernetes.io/aws-ebs`, which only still
works because CSI migration translates it — the PVs it produces come out in
legacy `awsElasticBlockStore` format annotated
`pv.kubernetes.io/migrated-to: ebs.csi.aws.com`. Naming the CSI driver
directly skips a backwards-compatibility path that exists to be retired.

### Why here and not in Terraform

The cluster is created by the HCP Terraform run role, and
`enable_cluster_creator_admin_permissions = false` in `envs/prod/eks.tf`
deliberately leaves that role with no cluster admin access — the only access
entry is the AWS owner's own principal. A `kubernetes` provider in `envs/prod`
would have nothing to authenticate as, and granting the run role cluster
access to fix that would reverse a deliberate security decision for the sake
of one object.

### Applying it by hand (pre-M7 / fresh-cluster bootstrap only)

```
kubectl apply -f cluster/storageclass/gp3.yaml
```

Folded into an Argo CD Application (`argocd/applications/30-storageclass.yaml`)
as of Milestone 7 — this manual step is no longer the normal path.

### Note for a customer-managed KMS key

`encrypted: "true"` works with the account's AWS-managed `aws/ebs` key without
the EBS CSI driver's IRSA role holding any `kms:*` actions — EC2 handles the
grant. Switching to a customer-managed key **will** require adding
`kms:CreateGrant`, `kms:GenerateDataKeyWithoutPlaintext` and friends to
`AmazonEKS_EBS_CSI_Policy` in `envs/prod/irsa.tf`, or volume creation starts
failing with AccessDenied.
