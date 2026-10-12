# ambari

Apache Ambari running standalone — no managed Hadoop cluster — so that it can host the Clemlab
**KDPS view**, the console that deploys and governs data platform services on Kubernetes. The
server runs inside the cluster it manages and is meant to be deployed by Argo CD.

The chart deploys one Ambari server and nothing else. In particular it does **not** run a database:
Ambari keeps all of its state, including the KDPS view's configuration, in PostgreSQL, and a
production install points at a database you already run.

```
helm install ambari oci://registry.clemlab.com/clemlabprojects/charts/ambari \
  --namespace kdps --create-namespace \
  --set database.host=postgres.databases.svc.cluster.local \
  --set database.existingSecret=ambari-db \
  --set masterKey.existingSecret=ambari-master-key \
  --set adminPassword.existingSecret=ambari-admin \
  --set route.host=ambari.apps.example.com
```

Sign in as `admin` with the password from the `ambari-admin` Secret. The server replaces Ambari's
default `admin` / `admin` with it before the pod is Ready, so the Route never serves the default (see
[The first administrator password](#the-first-administrator-password)).

**Before your first install**, read [OPERATIONS.md](OPERATIONS.md) §1: the chart creates no secrets
of its own, and the master key it needs must never change once anything has been encrypted with it.

## Requirements

* OpenShift 4.16 or later if you want the Route to serve your own certificate
  (`route.tls.externalCertificate` was introduced there). Everything else works on plain Kubernetes
  through `ingress.*`.
* A PostgreSQL database and a role that can create tables in it. The schema is loaded on first
  start when the database is empty.
* A `ReadWriteOnce` StorageClass. See [Persistence](#persistence) for what is kept and why.

The image runs as an arbitrary non-root UID, so no SCC beyond `restricted-v2` is needed.

## The database

The chart never provisions a database; it only connects to one. Point it at yours and choose where
the password comes from:

| Source | Values |
| --- | --- |
| A Secret you already manage | `database.existingSecret`, `database.existingSecretPasswordKey` |
| Vault | `global.vault.*` and `vault.csi.database.*` — see [Vault](#vault) |
| Inline (development only) | `database.password` |

```yaml
database:
  host: postgres.databases.svc.cluster.local
  port: 5432
  name: ambari
  user: ambari
  existingSecret: ambari-db
  existingSecretPasswordKey: password
```

## The master key

Required, and the chart will not render without it. Ambari encrypts its credential store with it and
the KDPS view encrypts your uploaded kubeconfig with it; with no key the view falls back to a
passphrase that is a constant in the published source.

```yaml
masterKey:
  existingSecret: ambari-master-key
  existingSecretKey: master-key
```

It must exist before the release is installed and it must never change. The chart deliberately does
not generate one — a generated value would be re-generated on every Argo CD sync. See
[OPERATIONS.md](OPERATIONS.md) §1.1.

## The first administrator password

Required, and the chart will not render without it. On an empty database Ambari creates its `admin`
account with the password `admin`, which is in Ambari's public documentation, and has no lockout on
failed sign-ins by default. On its first start the server replaces that password with this one,
through its own API on the loopback, and the pod becomes Ready only afterwards — so the Service and
the Route never send anyone to a console that accepts `admin` / `admin`.

| Source | Values |
| --- | --- |
| A Secret you already manage | `adminPassword.existingSecret`, `adminPassword.existingSecretKey` (default `password`) |
| Vault | `global.vault.*` and `vault.csi.adminPassword.*` — see [Vault](#vault) |
| Inline (development only) | `adminPassword.value` |

```yaml
adminPassword:
  existingSecret: ambari-admin
  existingSecretKey: password
```

It sets the **first** password only. Once the password is no longer the default — set from the
Secret, or changed in the UI — later starts leave it alone, so changing the Secret afterwards changes
nothing: change the password in Ambari. A restored database keeps the password it had. An `admin`
account that is disabled or locked out is left alone too, with a warning in the pod logs: `admin` /
`admin` cannot sign in to it, and neither can the server to change it. See
[OPERATIONS.md](OPERATIONS.md) §1.3.

`adminPassword.allowDefault=true` renders without a password and keeps `admin` / `admin` until
someone changes it. It is meant for a throwaway development install, never for one the Route
exposes.

The image does this: with `ambari-kdps` 2.8.2.0-160 and earlier nothing replaces the password and the
pod never becomes Ready, so keep `image.tag` at the chart's default or later. A released chart's
default is always a later image; from a git checkout, check `appVersion` in `Chart.yaml`. Charts up
to 0.1.10 do not set the password at all; with one of those, install with `route.enabled=false`,
change the password through `oc port-forward`, then turn the Route on
([OPERATIONS.md](OPERATIONS.md) §2). A release installed with one of those needs `adminPassword`
before it moves to this chart, and may need the password before it moves to a newer image: see
[OPERATIONS.md](OPERATIONS.md) §4 before you sync.

## Agents

Ambari here manages Kubernetes, not a fleet of hosts, so `agent.enabled` is `false`. That removes
the agent SSL listeners and, with them, the certificate authority Ambari generates with openssl on
first start. Turn it on only if this server also manages Ambari agents.

## TLS on the server itself

`api.tls.enabled` makes Ambari terminate TLS on 8443. The certificate comes from a
`kubernetes.io/tls` Secret, or straight out of Vault, and an init container converts it into the
PKCS12 keystore Ambari expects — the keystore password is generated per pod and never leaves the
pod. With this on there is no plain HTTP listener left, so `route.tls.mode` has to be `passthrough`
or `reencrypt`; the chart rejects the other combinations at template time.

```yaml
api:
  tls:
    enabled: true
    existingSecret: ambari-api-tls
route:
  host: ambari.apps.example.com
  tls:
    mode: passthrough
```

## TLS on the Route

`route.tls.mode` picks how the Route terminates TLS:

| Mode | What happens |
| --- | --- |
| `edge` | the router terminates TLS with the cluster's default certificate |
| `edgeWithCert` | the router terminates TLS with **your** certificate, read from a Secret |
| `passthrough`, `reencrypt` | only meaningful once Ambari itself serves HTTPS |

With `edgeWithCert` the certificate stays in its Secret and is referenced through the Route's
`externalCertificate` field rather than inlined, so the rendered manifest carries no private key and
Argo CD neither stores nor diffs it. The Secret is named after the route it serves —
`<route.host>-tls` — unless you set `route.tls.secretName`. The chart also grants the ingress router
read access to that one Secret; set `route.tls.grantRouterAccess=false` if your cluster
administrator has already arranged it.

## Vault

The master key, the first administrator password, the database password and the route certificate
can all come from Vault through the Secrets Store CSI driver. They are synced into ordinary
Kubernetes Secrets, so the Deployment and the Route consume them the same way whether Vault is
involved or not.

```yaml
global:
  vault:
    enabled: true
    address: https://vault.vault.svc:8200
    auth:
      kubernetes:
        role: kdps-ambari
vault:
  csi:
    masterKey:
      enabled: true
      path: secret/data/kdps/ambari/master-key
    adminPassword:
      enabled: true
      path: secret/data/kdps/ambari/admin
    database:
      enabled: true
      path: secret/data/kdps/ambari/db
    apiCert:
      enabled: true
      path: secret/data/kdps/ambari/api-cert
    routeCert:
      enabled: true
      path: secret/data/kdps/ambari/route-cert
```

The certificate Ambari serves is read straight from the CSI mount rather than through a synced
Secret, so there is no pod that needs a Secret only a running pod can create.

Two things the cluster has to provide first.

**The namespace must allow the driver's inline volume.** Without it the Deployment never creates a
ReplicaSet, and the only sign is a `ReplicaSetCreateError` on the Deployment:

```
oc label ns kdps \
  pod-security.kubernetes.io/enforce=privileged \
  security.openshift.io/scc.podSecurityLabelSync=false
```

**Vault must have a role bound to this release's ServiceAccount**, granting read on those paths:

```
vault write auth/kubernetes/role/kdps-ambari \
  bound_service_account_names=ambari \
  bound_service_account_namespaces=kdps \
  policies=kdps-ambari ttl=1h
```

One consequence is worth knowing: a Secret produced by the CSI driver exists only while a pod that
mounts it is running. When the route certificate comes from Vault, the Route cannot be created until
the server's pod is up, so the chart puts the Route in a later Argo CD sync wave. With plain `helm
install` the first pass is rejected — install with `route.tls.mode=edge` and switch afterwards, or
simply run the install a second time.

## Persistence

Ambari's state lives in the database. One thing on disk has to survive a restart: the KDPS view's
working directory, `resources/views/k8s-view-data/`, which holds the uploaded kubeconfig.

The claim is mounted on exactly that sub-path. Everything else under `/var/lib/ambari-server`
belongs to the image, so an image upgrade brings new stacks and view jars with it. The claim carries
`helm.sh/resource-policy: keep`, so `helm uninstall` does not take the kubeconfig with it.

If the view authenticates to OpenShift with an API URL and an account rather than a kubeconfig, that
is held in the Ambari database and there is nothing on disk to keep — you can run with
`persistence.enabled=false`.

## Logs and the audit trail

The pod logs carry the server log and Ambari's security audit log — sign-ins, refused access,
changes to users, groups and privileges — with every audit line prefixed `[ambari-audit] `. Collect
them with the cluster's log stack: the log files under `/var/log/ambari-server` go with the pod.

The image copies the audit log to the pod logs. `ambari-kdps` 2.8.2.0-160 and earlier do not, so keep
`image.tag` at the chart's default or later.

| Value | Default | |
| --- | --- | --- |
| `logs.persistence.enabled` | `false` | keep the log files on a volume: `type: emptyDir` (survives a container restart) or `type: pvc` (survives a new pod) |
| `logs.rotation.enabled` | `true` | keep 5 rotated files of the server and audit logs instead of the server's own, much larger, settings |
| `resources.*.ephemeral-storage` | `1Gi` / `3Gi` | sized for the rotation above |

See [OPERATIONS.md](OPERATIONS.md) §5.

## Stopping the pod

On SIGTERM the server is given `stopTimeoutSeconds` (50) to stop cleanly — the KDPS view lets the
operations in progress finish and Jetty closes its connections — before it is killed.
`terminationGracePeriodSeconds` (90) has to be at least 5 seconds longer, and the chart refuses to
render otherwise. The image's entrypoint does this: with `ambari-kdps` 2.8.2.0-160 and earlier,
`stopTimeoutSeconds` has no effect and the server is killed as soon as the pod is asked to stop.

## Deploying with Argo CD

The Route and the Deployment are annotated with sync waves, so Argo CD applies them in the order the
Vault case needs. A typical repository keeps the chart's values under `manifests/` and one
ApplicationSet per environment under `applicationSets/`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ambari
  namespace: openshift-gitops
spec:
  project: kdps
  source:
    repoURL: registry.clemlab.com/clemlabprojects/charts
    chart: ambari
    targetRevision: 0.1.0
    helm:
      valueFiles: []
      values: |
        database:
          host: postgres.databases.svc.cluster.local
          existingSecret: ambari-db
        masterKey:
          existingSecret: ambari-master-key
        adminPassword:
          existingSecret: ambari-admin
        route:
          host: ambari.apps.example.com
          tls:
            mode: edgeWithCert
  destination:
    server: https://kubernetes.default.svc
    namespace: kdps
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

## Pointing the view at a cluster

Once the server is up, sign in as `admin` with the first administrator password and configure the
KDPS view once:

* **OpenShift** — KDPS → Configuration → log in with the API URL and an account that can deploy.
  Stored in the Ambari database, so it survives pod restarts and upgrades.
* **Kubernetes** — KDPS → Configuration → upload a kubeconfig. That one is a file under
  `/var/lib/ambari-server`, so keep `persistence.enabled=true`.

## Updating the view without rebuilding the image

A view jar mounted at `/opt/ambari-views` is installed at start-up:

```yaml
views:
  configMap: kdps-view-jar     # or views.existingClaim
```

## Values

See [values.yaml](values.yaml); every option is documented there.

## Operating it

[OPERATIONS.md](OPERATIONS.md) covers what to create before the first sync, what must never change,
upgrades, backup and restore, and what the failure modes actually look like.
