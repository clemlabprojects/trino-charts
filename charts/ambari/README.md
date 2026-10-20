# ambari

Apache Ambari running standalone — no managed Hadoop cluster — so that it can host the Clemlab
**KDPS view**, the console that deploys and governs data platform services on Kubernetes. The
server runs inside the cluster it manages and is meant to be deployed by Argo CD.

The chart deploys one Ambari server and nothing else. In particular it does **not** run a database:
Ambari keeps its state, including the KDPS view's configuration, in PostgreSQL, and a production
install points at a database you already run. What the view keeps on disk is on a claim
([Persistence](#persistence)).

```
# the secrets named here are created first: OPERATIONS.md section 1
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
  start when the database holds none, in one transaction; when that fails, psql's error is in the
  pod logs and nothing of the schema is kept.
* A `ReadWriteOnce` StorageClass. The claim holds the KDPS internal CA and the saved Git
  credentials; see [Persistence](#persistence) for what is kept and why.

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

## Upgrading Ambari

Each Ambari line — the first three numbers of the image's version, so every 2.8.2.x image is the
2.8.2 line — has a database schema of its own, and the server does not start on another line's.
Before it starts the server, the pod compares the database's schema with the image and says in its
logs what it found:

| `image.tag` moves | What happens |
| --- | --- |
| within the same line | nothing else to do; rolling back is just as safe |
| to a later line, `schemaUpgrade.enabled: false` (the default) | the pod stops before the server starts, names both versions and changes nothing; setting the tag back recovers |
| to a later line, `schemaUpgrade.enabled: true` | the schema is upgraded before the server starts. Back the database up first, and turn the value off again once the pod is Ready |
| back to an earlier line after an upgrade | the pod stops: a schema is never downgraded. Restore the backup taken before the upgrade |

```yaml
schemaUpgrade:
  enabled: true      # only for the sync that moves image.tag to a new line, after a backup
```

The full procedure, and how to go back, is in [OPERATIONS.md](OPERATIONS.md) §4. A backup restores
only onto an image of the line it was taken with ([OPERATIONS.md](OPERATIONS.md) §7).

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
pod. With this on there is no plain HTTP listener left, so the Route passes TLS through or
re-encrypts it: leave `route.tls.mode` empty and the chart picks `reencrypt` when
`route.tls.destinationCACertificate` is set, `passthrough` otherwise. An `edge` or `edgeWithCert`
Route in front of it is rejected at template time.

```yaml
api:
  tls:
    enabled: true
    existingSecret: ambari-api-tls
route:
  host: ambari.apps.example.com      # the Route passes TLS through to Ambari
```

Without it the router — or the ingress controller — decrypts, and the last hop to the pod is plain
HTTP: sign-ins, the administrator's password and every secret uploaded to KDPS cross the cluster
network in clear, and the release notes say so. Turn it on for a production install.

On vanilla Kubernetes the Ingress sends the traffic to the HTTPS port once this is on, and the
controller has to be told to speak HTTPS to it, which is controller-specific. With ingress-nginx:

```yaml
ingress:
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: HTTPS
```

## TLS on the Route

`route.tls.mode` picks how the Route terminates TLS:

| Mode | What happens |
| --- | --- |
| *(empty, the default)* | follows `api.tls.enabled`: `edge` without it; with it `reencrypt` when `destinationCACertificate` is set, `passthrough` otherwise |
| `edge` | the router terminates TLS with the cluster's default certificate; plain HTTP to the pod |
| `edgeWithCert` | the router terminates TLS with **your** certificate, read from a Secret; plain HTTP to the pod |
| `passthrough` | the router does not decrypt; the browser sees Ambari's own certificate (needs `api.tls`) |
| `reencrypt` | the router decrypts and re-encrypts to Ambari, verifying its certificate against `destinationCACertificate` (needs `api.tls`) |

With `edgeWithCert` the certificate stays in its Secret and is referenced through the Route's
`externalCertificate` field rather than inlined, so the rendered manifest carries no private key and
Argo CD neither stores nor diffs it. The Secret is named after the route it serves —
`<route.host>-tls` — unless you set `route.tls.secretName`. The chart also grants the ingress router
read access to that one Secret; set `route.tls.grantRouterAccess=false` if your cluster
administrator has already arranged it.

## Who can connect to the server

Without a NetworkPolicy, any pod in the cluster can open a connection to the console. Nothing but the
router — or the ingress controller — needs to: the KDPS view runs inside the server, and the
kubelet's probes are not filtered by NetworkPolicy. `networkPolicy.enabled` admits connections to
the server's port only from the router's namespaces and the address ranges you list:

```yaml
networkPolicy:
  enabled: true
  # the defaults are the labels of OpenShift's router namespaces; on Kubernetes name your controller's:
  # ingressNamespaceSelectors:
  #   - kubernetes.io/metadata.name: ingress-nginx
  allowedCIDRs: []          # e.g. a load balancer's source range, a bastion
  extraFrom: []             # any other NetworkPolicyPeer, as it is
```

On OpenShift the defaults admit the routers of both network plugins. Routers on the host network
(bare metal, CRC) connect from the node instead: with OVN-Kubernetes add
`policy-group.network.openshift.io/host-network: ""` to `ingressNamespaceSelectors`. With no selector,
range or peer at all the policy admits nobody and the console is reachable through `port-forward`
only; an empty label set, which would admit every namespace, is refused. Outgoing traffic is not
restricted: the cluster API, the database, Vault, Git and the Helm repositories differ from one
installation to the next. The policy is off by default, so that an install on a cluster whose router
namespaces carry other labels keeps working; the release notes warn while it is off.

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

Ambari's state lives in the database, but the KDPS view keeps some of its own on disk, and that has
to survive a new pod — an upgrade, a node drain, an eviction. The claim is mounted on two sub-paths
of `/var/lib/ambari-server`:

| Sub-path | Holds |
| --- | --- |
| `resources/views/k8s-view-data/` | the view's working directory: the **KDPS Internal CA** that signs the certificates of the services KDPS deploys (`<instance>/ca`), operation parameters and logs, Helm repository and registry settings, Flux workspaces, and the uploaded kubeconfig |
| `keys/` | Ambari's **credential store**, shared by the server and the view: the Git tokens and SSH keys of GitOps releases. It is encrypted with the master key, which is not on the claim |

An init container copies into `keys/` the files of the image's that the claim does not have yet, and
never replaces one. Everything else under `/var/lib/ambari-server` belongs to the image, so an image
upgrade brings new stacks and view jars with it. The claim carries `helm.sh/resource-policy: keep`,
so `helm uninstall` leaves it behind.

Keep it, whichever way the view signs in to the cluster. Without it, every new pod signs
certificates with a new internal CA, so the services deployed before it and those deployed after it
no longer trust each other — Superset can no longer reach Trino over TLS, for one — and it forgets
the Git credentials, so GitOps releases cannot be upgraded or uninstalled until they are entered
again. The chart therefore refuses `persistence.enabled=false` unless
`persistence.acknowledgeEphemeral=true` says that is intended, and the release notes then carry a
warning: for a throwaway install only.

Back the claim up with the database and the master key, and restore it before the first deploy:
[OPERATIONS.md](OPERATIONS.md) §7.

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
    targetRevision: 0.1.14
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

## Supported platforms

What the chart and the KDPS view of the image it names are validated against. A version outside
these may work; it is not one the release was checked on.

| | Validated |
| --- | --- |
| Chart and image | chart 0.1.14 runs the `ambari-kdps` image named by its `appVersion`. Install a chart with the image it was released with: an earlier `image.tag` lacks what the chart relies on (OPERATIONS.md §2) |
| OpenShift | 4.16 or later (the Route serving your own certificate needs it); validated on OpenShift Local (CRC) and a 4.x cluster of the development environment |
| Kubernetes | a current release with `ingress.*` in place of the Route |
| PostgreSQL | 16, which the image tests run against; the client in the image is the UBI 9 one. From 15 on, a user that does not own the database needs a grant on its `public` schema |
| Helm | 3.22.0, the CLI in the image; releases are installed with the Helm library inside the view |
| Flux (GitOps deployments) | 2.3 or later, with the prerequisites in OPERATIONS.md §2, "GitOps (Flux)". KDPS writes `v2` and `v1` and reads the version the cluster serves |
| KEDA / Custom Metrics Autoscaler | the Custom Metrics Autoscaler operator on OpenShift and KEDA 2.x on Kubernetes, watching the projects KDPS deploys to (OPERATIONS.md §2, "An account limited to its own projects") |
| Argo CD / OpenShift GitOps | deploys this chart; any release that renders Helm 3 charts |

| Chart | Ambari / KDPS view build it needs |
| --- | --- |
| 0.1.9 | 2.8.2.0-160; superseded |
| 0.1.13 and later | an image built after 2.8.2.0-160 from the view that finds out it runs in a pod from the `KUBERNETES_SERVICE_*` variables, since the chart mounts no token by default. With an earlier image set `serviceAccount.automountToken=true`. `appVersion` in `Chart.yaml` names the image to use once a build contains it |
| 0.1.14 | 2.8.2.0-166 (its `appVersion`) |

## Pointing the view at a cluster

Once the server is up, sign in as `admin` with the first administrator password and configure the
KDPS view once. For production use a ServiceAccount: the pod's own (first below), or a kubeconfig
holding the token of a ServiceAccount made for KDPS. An uploaded `oc login` kubeconfig expires within
a day, and an OpenShift login needs a person's password kept in KDPS. The pod's ServiceAccount is
used only when you chose it there; the grants KDPS needs belong to the account it connects as.

* **This pod's ServiceAccount** — with `inClusterServiceAccount.enabled=true`, KDPS → Configuration →
  *Connect with this ServiceAccount*. No credential to upload or store, and Kubernetes renews the
  token itself: the way to connect when the OpenShift console only signs in through SSO. The value
  mounts the token even when the ServiceAccount opts out of it. The chart grants the ServiceAccount
  nothing: give it `admin` and, on OpenShift, `monitoring-edit` in each project KDPS deploys to
  ([OPERATIONS.md](OPERATIONS.md) §2). It needs the image this chart names (`appVersion`) or a later
  one: an earlier `image.tag` may not offer it.
* **OpenShift** — KDPS → Configuration → log in with the API URL and an account that can deploy.
  Stored in the Ambari database, so it survives pod restarts and upgrades.
* **Kubernetes** — KDPS → Configuration → upload a kubeconfig. That one is a file under
  `/var/lib/ambari-server`, so keep `persistence.enabled=true`. A kubeconfig holding a ServiceAccount
  token works the same way; OPERATIONS.md §2 shows how to write one.

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
