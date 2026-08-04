# Cluster-scoped resources

Objects that belong to the cluster itself rather than to the application —
applied once per cluster, before any release.

## `storageclass-gp3.yaml`

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

### Applying it

```
kubectl apply -f cluster/storageclass-gp3.yaml
```

Milestone 7 should fold this into an Argo CD Application so it stops being a
manual step.

### Note for a customer-managed KMS key

`encrypted: "true"` works with the account's AWS-managed `aws/ebs` key without
the EBS CSI driver's IRSA role holding any `kms:*` actions — EC2 handles the
grant. Switching to a customer-managed key **will** require adding
`kms:CreateGrant`, `kms:GenerateDataKeyWithoutPlaintext` and friends to
`AmazonEKS_EBS_CSI_Policy` in `envs/prod/irsa.tf`, or volume creation starts
failing with AccessDenied.
