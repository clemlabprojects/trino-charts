# Running Ambari as the KDPS operator

This is the operator's guide to the `ambari` chart: what you have to create before the first sync,
what must never change afterwards, and what to do when something breaks. It assumes Argo CD deploys
the chart and that you are running on OpenShift.

For what the chart *is* and every value it takes, see [README.md](README.md).

---

## 1. What you create before the first install

The chart creates no secrets of its own. That is deliberate: a value the chart generated would be
re-generated on the next Argo CD sync, and some of these cannot change without losing data.

Everything below has to exist **before** the Application syncs.

### 1.1 The master key — required, and permanent

Ambari encrypts its credential store with this key, and the KDPS view encrypts the kubeconfig you
upload with it. There is no default: the server refuses to start without one, because the view would
otherwise fall back to a passphrase that is a constant in the published source.

> **Rotating it makes everything already encrypted with it unreadable.** Treat it like a database
> encryption key: generate once, back it up somewhere you can still reach if the cluster is gone,
> and do not change it.

```
openssl rand -base64 32 | tr -d '=+/' | cut -c1-32     # generate once, keep it
```

Either as a plain Secret:

```
oc -n kdps create secret generic ambari-master-key --from-literal=master-key='<the key>'
```

```yaml
masterKey:
  existingSecret: ambari-master-key
  existingSecretKey: master-key
```

or from Vault:

```
vault kv put secret/kdps/ambari/master-key master-key='<the key>'
```

```yaml
vault:
  csi:
    masterKey:
      enabled: true
      path: secret/data/kdps/ambari/master-key
```

### 1.2 The database password

The chart connects to a PostgreSQL you already run — in the cluster, or on a physical host. It never
provisions one. Create the database and a role that can create tables in it, then:

```
oc -n kdps create secret generic ambari-db --from-literal=password='<the password>'
```

```yaml
database:
  host: pg01.corp.example.com
  name: ambari
  user: ambari
  existingSecret: ambari-db
  existingSecretPasswordKey: password
```

A database outside the cluster normally wants TLS. Those are driver properties:

```yaml
database:
  properties:
    ssl: "true"
    sslmode: verify-full
    sslrootcert: /vault/secrets/pg-ca.pem
```

The schema is loaded automatically on first start when the database holds no Ambari schema, in a
single transaction: when the load fails, nothing of it is kept, the pod logs show psql's error, and
the container exits. From PostgreSQL 15 on, a role that does not own the database cannot create
tables in its `public` schema until it is granted the right:

```
GRANT CREATE ON SCHEMA public TO ambari;
```

The tables go where the role's `search_path` puts them: in `public`, unless the database has a schema
named after the role. Either way works; the pod finds them there on every start and points the server
and the schema upgrade (§4) at that schema.

### 1.3 The first administrator password — required

On an empty database Ambari creates its `admin` account with the password `admin`. That password is
in Ambari's public documentation, nothing forces a change at the first sign-in, and by default failed
sign-ins lock nothing. So the chart requires the first password up front: on its first start the
server replaces `admin` / `admin` with it, through its own API on the loopback, and only then reports
Ready. The Service and the Route send nobody to it before that. Without a password the chart does not
render.

```
oc -n kdps create secret generic ambari-admin --from-literal=password='<the password>'
```

```yaml
adminPassword:
  existingSecret: ambari-admin
  existingSecretKey: password
```

or from Vault:

```
vault kv put secret/kdps/ambari/admin password='<the password>'
```

```yaml
vault:
  csi:
    adminPassword:
      enabled: true
      path: secret/data/kdps/ambari/admin
```

Use `--from-literal` rather than `--from-file`: a file usually ends with a newline, and that newline
would become part of the password.

It sets the **first** password only. On every start the server checks whether the account still has
the password the schema was created with — by reading the stored digest, not by trying `admin` /
`admin` at the login, so nothing counts towards a lockout — and leaves any other password alone.
Change the password in Ambari whenever your policy says so; the Secret is not read again, and editing
it changes nothing. A database restored from a backup keeps the password it had.

An `admin` account that still has the default password but is disabled, or locked out after
`authentication.local.max.failures` failed sign-ins, is left alone, with a warning in the pod logs,
and the pod becomes Ready: the server turns `admin` / `admin` away from such an account, and the
password can only be changed by signing in. Give it another password from another administrator
account before you enable or unlock it.

When the password cannot be set — the server's password policy (`security.password.policy.regexp`)
refuses it, or the API does not answer within five minutes — the container exits with the reason in
its log rather than serve `admin` / `admin`, and Kubernetes restarts it (§6).

`adminPassword.allowDefault=true` is for a throwaway development install only: the chart renders
without a password and the server keeps `admin` / `admin`, with a warning in the pod logs and the
release notes.

### 1.4 The certificates

Two different certificates, and you may want both:

| | Serves | Needs |
| --- | --- | --- |
| `api.tls` | Ambari itself, on 8443 | a `kubernetes.io/tls` Secret or Vault path; the chart converts it to the PKCS12 keystore Ambari wants |
| `route.tls.mode: edgeWithCert` | the OpenShift router | a `kubernetes.io/tls` Secret named `<route.host>-tls` |

For a production install, terminate TLS at Ambari and let the router pass it through, so nothing in
between sees plaintext:

```yaml
api:
  tls:
    enabled: true
route:
  host: ambari.apps.example.com
  tls:
    mode: passthrough
vault:
  csi:
    apiCert:
      enabled: true
      path: secret/data/kdps/ambari/api-cert
```

The certificate must name the **route host**, because with passthrough that is the name the browser
verifies. Use `reencrypt` instead if you want the router to terminate and re-encrypt; then the
router verifies Ambari's certificate, so a private CA has to go in
`route.tls.destinationCACertificate`.

The chart refuses to render if the Route and the server disagree — an `edge` route in front of an
HTTPS-only server gives a 503 with no explanation, so it is rejected at template time instead.

### 1.5 If you use Vault

Two cluster-side prerequisites, both easy to forget:

**The namespace must allow the CSI driver's inline volume.** Without this the Deployment never
creates a ReplicaSet and the only evidence is a `ReplicaSetCreateError` on the Deployment:

```
oc label ns kdps \
  pod-security.kubernetes.io/enforce=privileged \
  security.openshift.io/scc.podSecurityLabelSync=false
```

**Vault needs a role bound to this release's ServiceAccount:**

```
vault policy write kdps-ambari - <<'EOF'
path "secret/data/kdps/ambari/*" { capabilities = ["read"] }
EOF

vault write auth/kubernetes/role/kdps-ambari \
  bound_service_account_names=ambari \
  bound_service_account_namespaces=kdps \
  policies=kdps-ambari ttl=1h
```

---

## 2. Installing

```
oc new-project kdps
oc label ns kdps pod-security.kubernetes.io/enforce=privileged \
                 security.openshift.io/scc.podSecurityLabelSync=false   # only with Vault
# create the secrets from section 1
```

Then point Argo CD at the chart. The Deployment and the Route are in different sync waves, so Argo
CD brings them up in the right order.

With plain helm and a Vault-supplied **route** certificate, the first install is rejected: that
Secret only exists while a pod is mounting it. Install with `route.tls.mode=edge` and switch
afterwards, or just run the install twice. This does not apply to `passthrough`, which needs no
Secret on the Route at all.

First start takes a few minutes: the schema is created, the views are extracted and the first
administrator password replaces the default. The pod is Ready once that is done.

Sign in as `admin` with the password from §1.3.

This needs chart 0.1.11 or later with an `ambari-kdps` image later than 2.8.2.0-160. A released
chart names such an image as its default: it is not released until it does. Installed from a git
checkout of the chart instead, check `appVersion` in `Chart.yaml`, and set `image.tag` if it is
2.8.2.0-160 or earlier. With other combinations:

* **An earlier image** sets no password, so with this chart the pod never becomes Ready.
* **An earlier chart and an earlier image**: the server comes up with `admin` / `admin` and the Route
  serves it as soon as the pod is Ready. Until you can upgrade, keep it off the Route for the first
  start:
  1. Install with `route.enabled=false`.
  2. `oc -n kdps port-forward svc/ambari 8080:8080`, sign in at `http://localhost:8080` with
     `admin` / `admin`, and change the password: Manage Ambari → Users → admin.
  3. Set `route.enabled=true` and sync again.
* **An earlier chart and a later image**: on a new database, or one whose `admin` account still
  accepts `admin` / `admin`, the server refuses to start without the password. Give it through
  `extraEnv`:
  ```yaml
  extraEnv:
    - name: AMBARI_ADMIN_PASSWORD
      valueFrom:
        secretKeyRef: { name: ambari-admin, key: password }
  ```
  An installation whose administrator password was changed already starts without it (§4).

### Pointing the view at a cluster

* **The pod's own ServiceAccount** — with `inClusterServiceAccount.enabled=true`, KDPS →
  Configuration → Ambari's ServiceAccount → *Connect with this ServiceAccount*. Nothing to upload
  and no password to keep, so it is the way in when the OpenShift console only signs in through
  SSO. See the next section.
* **OpenShift** — KDPS → Configuration → log in with the API URL and an account that can deploy.
  Held in the Ambari database, so it survives restarts and upgrades.
* **Kubernetes** — KDPS → Configuration → upload a kubeconfig. That is a file under
  `/var/lib/ambari-server`, encrypted with the master key, and it needs `persistence.enabled=true`.
  If the file holds several contexts, pick one on the same page; KDPS and Helm both use it.

Whichever was saved last is used, by every user of the view. Saving another one switches to it.

### Connecting with Ambari's own ServiceAccount

When the cluster's console only signs in through SSO, KDPS has no password to log in with, and the
token of a kubeconfig copied from `oc login` expires within a day. KDPS can act instead as the
ServiceAccount the Ambari pod runs as (`serviceAccount` in the values: `ambari` in the release's
namespace by default):

1. **Turn it on.** Set `inClusterServiceAccount.enabled=true` and sync. The pod then has the
   ServiceAccount's token even when the ServiceAccount opts out of mounting it (one your platform
   team created with `automountServiceAccountToken: false`), and the release notes give the grants
   below for its name. The connection is in the KDPS view of the image this chart names
   (`appVersion`) and later ones: with `image.tag` set to an earlier image, Configuration may not
   offer it.
2. **Grant it, in each project KDPS deploys to,** what a deploy needs. The chart grants nothing:
   which projects KDPS manages is the platform team's decision. On OpenShift, with the release in
   `kdps`:

   ```
   oc -n <project> create rolebinding kdps-admin \
     --clusterrole=admin --serviceaccount=kdps:ambari
   oc -n <project> create rolebinding kdps-monitoring-edit \
     --clusterrole=monitoring-edit --serviceaccount=kdps:ambari
   ```

   `admin` lets KDPS install, upgrade and remove releases in the project; `monitoring-edit` lets it
   create their ServiceMonitors, which the autoscaling and the dashboards rely on (user workload
   monitoring must be enabled on the cluster). The ServiceAccount is then an account limited to its
   own projects, and "An account limited to its own projects" below applies as it is: projects
   created beforehand, KEDA, SCC grants (the commands there take `--serviceaccount=kdps:ambari` in
   place of `--user`), certificates.

   On Kubernetes, `admin` covers the releases themselves. ServiceMonitors, and KEDA ScaledObjects when
   autoscaling is used, need a Role of their own unless your Prometheus Operator and KEDA installs
   aggregate those rights to `admin`:

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: kdps-monitoring-autoscaling
     namespace: <project>
   rules:
     - apiGroups: [monitoring.coreos.com]
       resources: [servicemonitors, podmonitors, prometheusrules]
       verbs: [get, list, watch, create, update, patch, delete]
     - apiGroups: [keda.sh]
       resources: [scaledobjects, triggerauthentications]
       verbs: [get, list, watch, create, update, patch, delete]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: kdps-monitoring-autoscaling
     namespace: <project>
   roleRef:
     apiGroup: rbac.authorization.k8s.io
     kind: Role
     name: kdps-monitoring-autoscaling
   subjects:
     - kind: ServiceAccount
       name: ambari
       namespace: kdps
   ```
3. **Connect.** Sign in to Ambari, KDPS → Configuration. *Ambari's ServiceAccount* shows who KDPS
   will act as (`system:serviceaccount:kdps:ambari`) and the API server it reaches.
   *Connect with this ServiceAccount* saves the choice for every user and checks that the cluster
   answers. *Cluster prerequisites*, on the same page, then checks the grants of step 2 for a
   project.

Kubernetes renews the token in the pod before it expires, and KDPS reads the current one for every
call, Helm's included: there is nothing to rotate. Revoking access is removing the RoleBindings.

### A kubeconfig for a ServiceAccount

When Ambari does not run in the cluster it manages, or should act as an account other than its own
pod's, give KDPS a kubeconfig holding a ServiceAccount token instead: it is an ordinary kubeconfig
upload. Create the account in a project of its own and grant it per project as in step 2 above
(`--serviceaccount=kdps-system:kdps-deployer`). Then write the kubeconfig:

```
oc -n kdps-system create serviceaccount kdps-deployer
# A token that does not expire, held in a Secret; deleting the Secret revokes it.
oc -n kdps-system apply -f - <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: kdps-deployer-token
  annotations:
    kubernetes.io/service-account.name: kdps-deployer
type: kubernetes.io/service-account-token
YAML
TOKEN=$(oc -n kdps-system get secret kdps-deployer-token -o jsonpath='{.data.token}' | base64 -d)
CA=$(oc -n kdps-system get secret kdps-deployer-token -o jsonpath='{.data.ca\.crt}')
SERVER=$(oc whoami --show-server)
cat > kdps-deployer.kubeconfig <<KUBECONFIG
apiVersion: v1
kind: Config
clusters:
- name: cluster
  cluster:
    server: ${SERVER}
    certificate-authority-data: ${CA}
users:
- name: kdps-deployer
  user:
    token: ${TOKEN}
contexts:
- name: kdps-deployer
  context:
    cluster: cluster
    user: kdps-deployer
    namespace: <project>
current-context: kdps-deployer
KUBECONFIG
```

Upload `kdps-deployer.kubeconfig` under KDPS → Configuration, then delete the local copy: it is a
credential. KDPS keeps it encrypted with the master key, on the PVC. If the API server presents a
certificate from your own CA (a named certificate on OpenShift), put that CA, base64-encoded, in
`certificate-authority-data` instead. A token from `oc create token` works too, but it expires
(after an hour by default) and KDPS cannot renew it: the view then shows the cluster disconnected
until a new kubeconfig is uploaded.

### An account limited to its own projects

KDPS works with an account that administers its own projects and has no cluster-wide rights:
releases, events and the dashboard are read project by project, and the dashboard shows each
project's usage against its ResourceQuota. What changes:

* **Projects are created beforehand** by the platform team. KDPS installs into an existing project
  and only creates a namespace when the account is allowed to.
* **Autoscaling (KEDA / Custom Metrics Autoscaler on OpenShift).** Without the right to create a
  ClusterRoleBinding, KDPS points the autoscaler at Thanos's per-project port (9092) with a token
  limited to the project. Two grants are needed per project, and the deploy stops with the exact
  command when one is missing:
  * `oc policy add-role-to-user monitoring-edit <account> -n <project>`, so the release can create its
    ServiceMonitors. User workload monitoring must be enabled on the cluster.
  * The KEDA operator must watch the project. If it was installed with a `watchNamespace`
    restriction, add the project to it.
* **Security context constraints (OpenMetadata, JupyterHub).** Some of their pods pin a UID or run as
  root, which the default `restricted-v2` SCC refuses: OpenMetadata needs `anyuid` for its bundled
  OpenSearch and Airflow, JupyterHub needs `nonroot-v2` and `anyuid`. KDPS first checks whether the
  release's service accounts may already use them, and then changes nothing. A project admin may not
  grant an SCC, so otherwise the deploy stops and prints two ways out:
  * the platform team grants the SCCs to the release's service accounts with the printed command, for
    example `oc adm policy add-scc-to-user anyuid -z default -z om-airflow-scheduler ... -n <project>`.
    The next deploy finds the grant and writes nothing.
  * or, once per project, the platform team lets the account grant these SCCs itself:

    ```
    # once per cluster
    oc create clusterrole kdps-grant-scc --verb=bind --resource=clusterroles \
      --resource-name=system:openshift:scc:anyuid --resource-name=system:openshift:scc:nonroot-v2
    # once per project (for a service account: --serviceaccount=<project>:<name>)
    oc -n <project> create rolebinding kdps-grant-scc --clusterrole=kdps-grant-scc --user=<account>
    ```

    KDPS then grants each release its own RoleBinding per SCC, `kdps-scc-<scc>-<release>`, labelled
    `app.kubernetes.io/managed-by=ambari-kdps` and `ambari.clemlab.com/release=<release>`, and deletes it
    when the release is uninstalled. Installing another service in the project never changes it.

  When the platform team made the grant, the uninstall lists the matching
  `oc adm policy remove-scc-from-user` commands, since KDPS cannot take that grant back. They leave
  out the service accounts another KDPS release of the project still uses (OpenMetadata and
  JupyterHub both use the project's `default` service account). Likewise, a binding of the
  uninstalled release that another release still depends on is handed over to that release, or
  kept, with the commands to run before deleting it. A GitOps deploy started from KDPS checks and
  grants the same way before anything is committed to Git. The shared
  `kdps-scc-<scc>` RoleBinding of earlier versions is left in place; the uninstall suggests deleting
  it once no remaining release depends on it.
* **Certificates.** cert-manager ClusterIssuers are not visible to such an account. Use the Ambari
  internal CA (the default, kept on the PVC: §3) or a certificate issued by your own CA; add that CA
  under KDPS → Truststores so the deployed services trust each other.
* **GitOps (Flux).** Works the same way; the chart source written for Flux is the chart repository
  configured in KDPS.

---

## 3. What must not change

| | Why |
| --- | --- |
| the master key | everything encrypted with it becomes unreadable, including the credential store on the PVC and the uploaded kubeconfig |
| the database | Ambari's state and the KDPS view's: settings, platform contexts, releases, the OpenShift login |
| the PVC | what the KDPS view keeps on disk (below). It is annotated `helm.sh/resource-policy: keep`, so `helm uninstall` leaves it behind on purpose |

The PVC is mounted on two sub-paths of `/var/lib/ambari-server`:

| Sub-path | Holds | Lost with the PVC |
| --- | --- | --- |
| `resources/views/k8s-view-data/<instance>/ca/` | the **KDPS Internal CA** (`ambari-ca.crt`, `ambari-ca.key`), which signs the certificates of every service deployed with auto-generated TLS, and is the CA their truststores hold | KDPS generates a new CA the next time it needs one, such as at the next TLS deploy. The services deployed before it and those deployed after it no longer trust each other (Superset to Trino, for one), nor do clients outside KDPS that imported the old CA, until every TLS release is upgraded (§7) |
| `keys/credentials.jceks` | Ambari's **credential store**, shared by the server and the view: the Git token or SSH key of each GitOps release | upgrading a GitOps release fails with `GitOps over HTTPS requires authToken or sshKey` unless its token or key is given again in the upgrade form; uninstalling it is refused until it has been deployed once more with them; pull-request states stop refreshing |
| `resources/views/k8s-view-data/<instance>/` (the rest) | operation parameters and logs, Helm repository and registry settings, Flux workspaces, the uploaded kubeconfig | an operation in progress or retried runs without its parameters, past operation logs are gone, and the kubeconfig has to be uploaded again. Repository settings and Flux workspaces are built again when needed |

`<instance>` is the name of the KDPS view instance. Chart 0.1.11 and earlier did not keep `keys/` on
the PVC: see §4.

Safe to change at any time: the image tag within the same Ambari line (moving to a new line is §4),
the certificates, the route host, resources, the stop timeout and grace period, the logs settings,
replicas (keep it at 1 — the chart uses the `Recreate` strategy and a `ReadWriteOnce` claim). The
first administrator password's Secret can change too, but to no effect: it is only used while the
password is still the default (§1.3).

A release installed with chart 0.1.10 or earlier is the exception for the image tag and the chart
version: read §4 first, or the new pod may not start, and `Recreate` has already removed the old one.

---

## 4. Upgrading

Change `image.tag` and let Argo CD sync. The pod is replaced; stacks, view jars and the rest of
`/var/lib/ambari-server` come from the new image, which is why only the view's working directory and
`keys/` are on the PVC (§3) rather than the whole directory.

What else an upgrade needs depends on the Ambari **line**: the first three numbers of the image's
version. Each line has a database schema of its own, and the server does not start on another
line's. Before the server starts, the pod compares the two and says in its logs what it found.

### Within the same Ambari line: nothing else to do

Every image of a line runs on that line's schema: from `2.8.2.0-161` to `2.8.2.0-175`, or to a
`2.8.2.1` build, the pod starts as before, and its logs say
`the database schema (2.8.2) is the one Ambari 2.8.2.0 runs on`. Rolling the tag back within the line
is just as safe.

### To a new Ambari line: back up, then upgrade the schema

Moving to a new line (2.8.3, 2.9) needs the database schema upgraded, and the pod does that only when
asked to, after a backup. Without it the new pod stops before the server starts, changes nothing, and
says why:

```
[entrypoint] the database schema is Ambari 2.8.2, older than this server, Ambari 2.8.3.0, which
[entrypoint] runs on the 2.8.3 schema. Nothing was changed: an image of the 2.8.2 line still runs
[entrypoint] on this database. To upgrade the schema to 2.8.3, back the database up, then start this
[entrypoint] image with AMBARI_SCHEMA_UPGRADE=true (in the ambari chart, schemaUpgrade.enabled=true).
```

Setting `image.tag` back to the earlier image recovers from that: nothing was migrated.

To upgrade:

1. **Back the database up**, and keep the backup until the new line has proved itself:
   ```
   pg_dump -h pg01.corp.example.com -U ambari -Fc -f ambari-2.8.2-$(date +%F).dump ambari
   ```
   This backup is the only way back to the earlier line (below). Keep the master key's backup with
   it (§7); the upgrade does not change the key.
2. **Sync the new `image.tag` with the schema upgrade turned on:**
   ```yaml
   image:
     tag: 2.8.3.0-12
   schemaUpgrade:
     enabled: true
   ```
   The pod upgrades the schema before the server starts and then starts as usual. Its logs show
   `upgrading the database schema from 2.8.2 to 2.8.3`, what the upgrade did with any warning or
   error it logged, and then `upgraded the database schema to 2.8.3`. Read the warnings before going
   on: a change the upgrade could not make may be logged only as a warning.
3. **Once the pod is Ready, turn it off again** (`schemaUpgrade.enabled: false`) and sync, so that the
   next move to a new line waits for a backup again. Until you do, every start says
   `AMBARI_SCHEMA_UPGRADE=true has nothing to do`.

`schemaUpgrade` is in chart 0.1.12 and later. With an earlier chart, pass the same switch through
`extraEnv`:

```yaml
extraEnv:
  - name: AMBARI_SCHEMA_UPGRADE
    value: "true"
```

Leave the pod alone while the upgrade runs. It runs before the server listens, so within the time
the liveness probe gives the server to come up: `livenessProbe.initialDelaySeconds` plus
`periodSeconds` × `failureThreshold`, 300 seconds by default, which is ample for Ambari's own schema.
Should the pod logs show the container restarted during the upgrade, raise
`livenessProbe.initialDelaySeconds` for the upgrade sync.

**If the upgrade fails**, the container exits with the reason, taken from the server's log, and
while `schemaUpgrade.enabled` is on, each restart runs the upgrade again. Remove the cause, or go back
to the earlier line as below.

**Going back to the earlier line after an upgrade.** Once the schema is upgraded, an image of the
earlier line does not start on it, and nothing downgrades a schema:

```
[entrypoint] the database schema is Ambari 2.8.3, newer than this server, Ambari 2.8.2.0, and
[entrypoint] a schema is never downgraded: this server cannot run on it. Run an image of the 2.8.3 line,
[entrypoint] or restore the database backup taken before the schema was upgraded.
```

Rolling `image.tag` back is not enough: restore the backup taken in step 1 (§7) and set `image.tag` to
the earlier image. Whatever was changed in Ambari since the upgrade is lost with it.

### From chart 0.1.10 or earlier

Those charts pass no administrator password. With the `Recreate` strategy the old pod is gone before
the new one starts, so prepare these before you sync:

* **Moving to chart 0.1.11 or later**: the chart does not render without `adminPassword` (§1.3).
  Create the Secret, or the Vault path, and set it in the values with the new chart version. When the
  administrator password was changed already, the server leaves it alone and the Secret is not used
  on this database; a new one built from these values, such as a disaster-recovery copy, gets it, so
  put the current password in it.
* **Changing only `image.tag`** to an image later than 2.8.2.0-160: a release whose administrator
  password was changed starts as before, and the pod logs say `AMBARI_ADMIN_PASSWORD is not set, and
  none is needed`. One whose `admin` account still accepts `admin` / `admin` does not start until the
  password is given through `extraEnv` (§2); the server then replaces the default before the pod is
  Ready. If you are not sure which applies, add the `extraEnv` entry anyway: once the password has
  changed it is not used.

### From chart 0.1.11 or earlier

Those charts kept Ambari's credential store in the pod rather than on the PVC, and rendered with
`persistence.enabled=false`. With the `Recreate` strategy the old pod is gone before the new one
starts, so do these before you sync:

* **GitOps releases.** Their saved Git tokens and SSH keys are in the running pod's
  `keys/credentials.jceks`, and go with it. The first start with this chart puts the image's files in
  `keys/` on the PVC, without a credential store. To keep the saved credentials, copy the store out
  before the sync (when the file is there), and back once the new pod is Ready, before anyone deploys
  from KDPS:
  ```
  oc -n kdps exec deploy/ambari -c ambari -- cat /var/lib/ambari-server/keys/credentials.jceks > credentials.jceks
  # sync the new chart version and wait for the pod to be Ready
  oc -n kdps exec -i deploy/ambari -c ambari -- sh -c 'cat > /var/lib/ambari-server/keys/credentials.jceks' < credentials.jceks
  ```
  The copy is encrypted with the master key; delete it once it is back. Without it, give each GitOps
  release its Git access token or SSH key once more, in the form of its next upgrade from KDPS: it is
  kept from then on. A release deployed directly with Helm needs nothing.
* **`persistence.enabled=false`.** Earlier versions of the chart's README said an install that signs
  in to OpenShift with an API URL and an account could do without the PVC. This chart does not
  render that unless `persistence.acknowledgeEphemeral=true`, which is for throwaway installs. Turn
  persistence on instead. The new PVC starts empty, so copy the view's working directory, and the
  internal CA in it, out of the running pod before the sync, and back once the new pod is Ready,
  before anyone deploys from KDPS (the credential store too, as above):
  ```
  oc -n kdps exec deploy/ambari -c ambari -- tar -C /var/lib/ambari-server -cf - resources/views/k8s-view-data > k8s-view-data.tar
  # sync with persistence.enabled=true and wait for the pod to be Ready
  oc -n kdps exec -i deploy/ambari -c ambari -- tar -C /var/lib/ambari-server --no-overwrite-dir -xf - < k8s-view-data.tar
  oc -n kdps rollout restart deploy/ambari
  ```
  The archive holds the CA's private key: keep it no longer than this takes. If the CA is already
  lost, see §7.

---

## 5. Stopping the pod, and the audit trail

The clean stop and the audit lines in the pod logs both come from the image's entrypoint.
`ambari-kdps` 2.8.2.0-160 and earlier do neither: the server is killed as soon as the pod is asked to
stop, whatever `stopTimeoutSeconds` says, and the audit log stays in its file. Rolling `image.tag`
back to one of them (§4) brings both problems back.

### What happens when the pod stops

An upgrade, `oc rollout restart`, `oc delete pod`, a node drain and a failed liveness probe all stop
the pod the same way: Kubernetes sends SIGTERM, and kills whatever is left
`terminationGracePeriodSeconds` (90) later. On SIGTERM the container signals the server and gives it
`stopTimeoutSeconds` (50) to stop: the KDPS view lets the operations in progress finish, for about
30 seconds at most, and Jetty closes its connections. A clean stop reads like this in the pod logs:

```
[entrypoint] stopping the server
... KubernetesService - Shutting down KubernetesService static executor pools
... AmbariServer - Joined the Server
... CommandService - Shutting down all CommandService instances
[entrypoint] the server has stopped
```

`[entrypoint] the server is still running after 50s; killing it` means something held the shutdown
up; the lines before it say what was still running.

**A deployment running at that moment.** A Helm install or upgrade that needs longer than the stop
timeout is cut short. After the restart KDPS shows the operation as failed ("Operation interrupted
by server restart."), and the release may be left `pending-install` or `pending-upgrade`. Run the
operation again from KDPS: it recovers the release first — a first install that never completed is
uninstalled and installed again, an interrupted upgrade is rolled back to the last revision that
served and retried. Prefer to restart Ambari, or drain its node, when no deployment is running.

### The audit trail

Ambari records sign-ins and sign-outs, failed sign-ins, refused access, and every change to users,
groups, privileges, view instances and view privileges in its audit log. That log is in the **pod logs**, one line per
event, each prefixed with `[ambari-audit] `:

```
[ambari-audit] 2026-10-12T09:34:43.657Z, User(admin), RemoteIp(10.128.2.1), Operation(User login), Roles(Ambari: Ambari Administrator), Status(Success)
```

The file it comes from, `/var/log/ambari-server/ambari-audit.log`, is only a working copy: it is in
the container, so it goes with every new pod and, unless `logs.persistence` is on, with every
container restart. **Collect the pod logs with the cluster's log stack** (OpenShift Logging, or the
forwarder that feeds your SIEM) and keep the `[ambari-audit]` lines for as long as your audit policy
requires: the cluster's log store is the record. The prefix is there so a forwarder can route them
to their own index or retention.

The server's own log is in the pod logs as well, without a prefix.

### Keeping the log files

`logs.persistence` puts `/var/log/ambari-server` on a volume, for when the files themselves are
wanted:

| `logs.persistence.type` | The files survive |
| --- | --- |
| `emptyDir` | a container restart (crash, failed liveness probe), not a new pod. Counts against the pod's ephemeral storage; `sizeLimit` caps it |
| `pvc` | a new pod too. The claim is `<release>-ambari-logs`, or `existingClaim`; `helm uninstall` leaves it behind |

On vanilla Kubernetes the claim must be writable by the pod's group: set `podSecurityContext.fsGroup`.
OpenShift does that on its own.

### Disk use

The pod requests 1Gi of ephemeral storage and is limited to 3Gi. The logs fit in that because the
chart keeps 5 rotated files each of the server log (80 MB) and the audit log (50 MB, compressed when
rotated), instead of the server's own settings, which let the logs alone reach nearly 3 GB
(`logs.rotation`). It does so by mounting its own copy of the server's `logback.xml`. With
`logs.rotation.enabled=false`, raise the ephemeral-storage limit, or the pod is evicted once its logs
outgrow it.

---

## 6. When it does not work

**No pod at all, and nothing in the events for it.**
Look at the Deployment, not the pod. `ReplicaSetCreateError ... pod security enforce level that is
lower than privileged` means the namespace label from §1.5 is missing.

**`AMBARI_SECURITY_MASTER_KEY is not set: the master key is required.`**
The Secret named in `masterKey.existingSecret` does not exist, or the key inside it is not the one
in `masterKey.existingSecretKey`.

**`could not read the Ambari schema version from the database`.**
psql's error above it says why: usually `database.host`, `database.name`, `database.user` or the
password in the database Secret is wrong, or the database does not exist yet.

**`the Ambari schema could not be loaded, and nothing of it was kept`.**
The first start could not create the schema; psql's error is above it. `permission denied for schema
public` means the role cannot create tables (§1.2). `relation ... already exists` means the database
holds Ambari tables but no schema version: an image up to 2.8.2.0-160 began loading the schema and did
not finish. Start again from an empty database (`DROP DATABASE` and create it again).

**`the database schema is Ambari …, older than this server`.**
The image is of a newer Ambari line than the database. Nothing was changed. Either set `image.tag`
back to an image of the database's line, or upgrade the schema: §4.

**`the database schema is Ambari …, newer than this server`.**
The database was upgraded to a later line, and the image is of an earlier one: `image.tag` was rolled
back after a schema upgrade, or the database was restored from a backup of a later line. Set
`image.tag` to an image of the database's line, or restore a backup of this line (§7).

**`the schema upgrade failed; the server's log above says why`.**
The reason is in the lines above it. With `schemaUpgrade.enabled` still on, the next start runs the
upgrade again; once the cause is removed it completes. To give up instead, restore the backup taken
before the upgrade and set `image.tag` back (§4).

**`AMBARI_ADMIN_PASSWORD is not set: the first administrator password is required.`**
The database is new, or its `admin` account still accepts `admin` / `admin`, and no password reached
the container. The same as above, for `adminPassword.existingSecret` and
`adminPassword.existingSecretKey` (§1.3); with chart 0.1.10 or earlier, which passes none, give it
through `extraEnv` (§2). `AMBARI_ADMIN_PASSWORD is not set, and the database could not be read`
means the check could not tell; psql's error above it says why.
`AMBARI_ADMIN_PASSWORD is Ambari's public default password` means the Secret holds `admin`.

**The pod runs but never becomes Ready.**
The readiness check waits for the first administrator password to be set. The pod logs say where it
stands: `waiting for the server's API to set the administrator password` while the server is still
starting, then `set the administrator password from AMBARI_ADMIN_PASSWORD` or `the administrator
password is not the default one; leaving it as it is`. If none of these appear at all, the image is
2.8.2.0-160 or earlier and does not set the password: set `image.tag` to a later one (§4).

**`WARNING: the admin account is disabled but still has Ambari's default password`** (or `is locked
out after too many failed sign-ins`).
The pod is Ready and `admin` / `admin` cannot sign in, but the account keeps the public password
until someone changes it (§1.3). Give it another password from another administrator account before
enabling or unlocking it.

**`the server refused to set the administrator password (HTTP …)`, then the container exits.**
The reason the server gave follows; most often the password does not match the server's password
policy. Put a password that does in the Secret; the next start sets it. `the administrator password
could not be set within 300s` means the server's API never answered, and the server log above it
says why. `the server turned admin/admin away (HTTP 401)` means the server refused the default
password although the database shows the account enabled, not locked out and with that password;
the server log above it says why.

**The administrator password is lost.**
Put the default back in the database, enable and unlock the account, with the password you want in
the Secret, and restart the pod: the server finds the default again and replaces it before the pod
is Ready.

```
UPDATE user_authentication SET authentication_key =
  '538916f8943ec225d97a9a86a2c6ec0818c1cd400e09e03b660fdaaec4af29ddbb6f2b1033b81b00'
 WHERE authentication_type = 'LOCAL'
   AND user_id = (SELECT user_id FROM users WHERE user_name = 'admin');
UPDATE users SET active = 1, consecutive_failures = 0 WHERE user_name = 'admin';
```

**CrashLoopBackOff, and the pod logs end with the server's own log.**
The entrypoint prints the last 200 lines of `ambari-server.log` when a start fails, precisely
because the container is about to take that file with it. Read from the bottom.

**Route answers 503.**
The router cannot reach the server. Usually the Route and the server disagree about TLS — but the
chart rejects that combination at template time, so check the pod is `Ready` first.

**Login page loads, KDPS tab is empty.**
The view is installed but not configured. KDPS → Configuration.

**`The Ambari pod has no ServiceAccount token at /var/run/secrets/kubernetes.io/serviceaccount/token`.**
KDPS was asked to connect with the pod's ServiceAccount, and the pod has none mounted: the
ServiceAccount opts out of mounting it (`automountServiceAccountToken: false`). Set
`inClusterServiceAccount.enabled=true` and sync; the new pod has it. The configuration KDPS used
before is unchanged meanwhile.

**Connected with the ServiceAccount, but deploys stop with `forbidden`.**
The ServiceAccount has no grant in that project yet (§2, "Connecting with Ambari's own
ServiceAccount", step 2). *Cluster prerequisites* on the KDPS Configuration page lists what is
missing for a project.

**`Master key initialization failed` in the server log.**
The master key is not reaching the server. Anything the view encrypts from here on uses the
fallback passphrase, so fix it before uploading a kubeconfig.

**`persistence.enabled=false keeps the KDPS internal CA and the saved Git credentials in the pod`.**
The chart refuses to render without the PVC (§3). Set `persistence.enabled=true`, after copying
what the running pod holds (§4, from chart 0.1.11 or earlier).

**The pod stays in `Init` and the `seed-keys` container fails.**
It copies the image's files into `keys/` on the PVC and needs to write there. On vanilla Kubernetes
the claim must be writable by the pod's group: set `podSecurityContext.fsGroup`. OpenShift does that
on its own.

**Services deployed by KDPS reject each other's certificates after Ambari restarted.**
Superset cannot connect to Trino, for example, with `PKIX path building failed` or `certificate
verify failed`, and the pod logs say `Generating a new Ambari internal CA` at a deploy. The internal
CA was lost with the PVC, or with the pod when persistence was off: see "If the internal CA was
lost" in §7.

**`GitOps over HTTPS requires authToken or sshKey` when upgrading a GitOps release**, or the
uninstall says `The Git credential KDPS saved for it is no longer in Ambari's credential store`.
The credential store was lost: with chart 0.1.11 or earlier at every new pod, otherwise with the
PVC. Give the release's Git access token or SSH key in the upgrade form; it is kept from then on,
and the uninstall works again.

### Reading the logs

```
oc -n kdps logs deploy/ambari -c ambari                  # entrypoint + server + audit
oc -n kdps logs deploy/ambari -c ambari | grep '^\[ambari-audit\]'   # the audit trail only
oc -n kdps logs deploy/ambari -c ambari --previous       # the container before the last restart
oc -n kdps logs deploy/ambari -c https-keystore          # the certificate conversion
oc -n kdps logs deploy/ambari -c seed-keys               # what keys/ on the PVC holds
oc -n kdps exec deploy/ambari -- tail -100 /var/log/ambari-server/ambari-server.log
oc -n kdps exec deploy/ambari -- ambari-server status
```

`oc logs` only reaches back to the current container and the one before it; older audit lines are in
the cluster's log store (§5).

---

## 7. Backup and restore

What you need to be able to restore, all three:

1. **The database** — Ambari's state and the KDPS view's. `pg_dump` on your own schedule.
2. **The master key** — without it the database backup is unreadable, and so is the credential store
   on the PVC.
3. **The PVC** — the KDPS internal CA, the credential store with the Git credentials of GitOps
   releases, operation records and the uploaded kubeconfig (§3). Back it up when you back up the
   database: a GitOps release given a new Git token after the PVC's backup needs it again after a
   restore.

### Taking the backups

The database, for example:

```
pg_dump -h pg01.corp.example.com -U ambari -Fc -f ambari-2.8.2-$(date +%F).dump ambari
```

Name the dump after the Ambari line it was taken with, the first three numbers of `image.tag`: a
backup restores only onto an image of the **same line**. The server does not start on another
line's schema, and the pod says so (§6). A backup of an earlier line can be brought forward once it is
restored, with the schema upgrade (§4); one of a later line cannot be brought back to an earlier image.

The PVC: a VolumeSnapshot of the claim (`ambari`, or `persistence.existingClaim`) where the storage
supports snapshots, or the platform's backup tool. Otherwise copy its two directories out of the
running pod:

```
oc -n kdps exec deploy/ambari -c ambari -- tar -C /var/lib/ambari-server -cf - keys resources/views/k8s-view-data > ambari-files-$(date +%F).tar
```

That backup holds the internal CA's private key as it is: whoever reads it can issue certificates
that every service deployed with KDPS's auto-generated TLS trusts. Keep it as safe as the master
key's backup.

### Restoring

Recreate the master key Secret with the *same* key and restore the database into an empty one:

```
pg_restore -h pg01.corp.example.com -U ambari -d ambari --no-owner ambari-2.8.2-2026-10-12.dump
```

Then install the chart pointing at the database, with `image.tag` of the backup's line, and put the
PVC back **before the first deploy**: a deploy with TLS before then generates a new internal CA.

* From a snapshot: create a claim from it, and install with `persistence.existingClaim` set to it.
* From the archive: once the pod is Ready, and before anyone deploys from KDPS,
  ```
  oc -n kdps exec -i deploy/ambari -c ambari -- tar -C /var/lib/ambari-server --no-overwrite-dir -xf - < ambari-files-2026-10-12.tar
  oc -n kdps rollout restart deploy/ambari
  ```
  `--no-overwrite-dir` leaves the two mounted directories themselves alone, which the pod's user is
  not allowed to change.

The server finds the schema present — the pod logs say `the database schema (2.8.2) is the one
Ambari 2.8.2.0 runs on` — and starts against it. The administrator password is the one in the backup;
the `adminPassword` Secret is only used on an empty database.

### If the internal CA was lost

The internal CA is only on the PVC. When it is lost — with the PVC, or with the pod when persistence
was off — KDPS generates another one the next time it needs one, such as at the next deploy with
auto-generated TLS, and the pod logs say `Generating a new Ambari internal CA`. The releases deployed
from then on get certificates and truststores of the new CA, those deployed before keep the old
ones, and the two no longer trust each other: Superset cannot connect to Trino, for example.

1. If a backup of the PVC has the old CA, put it back (above). Then only the releases deployed with
   TLS since it was lost need step 2.
2. Otherwise keep the new CA, and in KDPS upgrade every release that uses auto-generated TLS, without
   changing its values. Each upgrade issues the release's certificates from the current CA and gives
   it a truststore holding that CA. Until the last one is upgraded, the services already upgraded
   and those not yet upgraded cannot talk to each other over TLS. A service that still presents its
   old certificate after its upgrade needs its pods restarted.
3. Give the current CA to whatever outside KDPS trusted the old one, such as clients that imported
   it:
   ```
   oc -n kdps exec deploy/ambari -c ambari -- sh -c 'cat /var/lib/ambari-server/resources/views/k8s-view-data/*/ca/ambari-ca.crt'
   ```

---

## 8. Notes on the security posture

* The server runs as an arbitrary non-root UID under `restricted-v2`. No added SCC, no privileged
  container, no `runAsUser`.
* The chart grants its ServiceAccount nothing. Its token is in the pod, as in any pod whose
  ServiceAccount does not opt out of it, so whoever controls the pod acts with the grants given to
  that ServiceAccount: when KDPS connects with it, give them project by project (§2), never
  cluster-wide.
* There are no Ambari agents, so `agent.enabled` is off. That removes the agent SSL listeners and
  the certificate authority Ambari would otherwise generate for them. Turn it on only if this
  server also manages Ambari agents — it brings the keystore requirements back with it.
* With `api.tls.enabled` there is no plain HTTP listener at all: the client connector is one or the
  other, never both.
* The keystore password is generated per pod and never leaves the pod's own `emptyDir`.
* The PVC holds the KDPS internal CA's private key as it is, readable only by the pod's user and
  group, and the credential store, encrypted with the master key. Whoever can read the claim, its
  snapshots or its backups can issue certificates the deployed services trust: give them the access
  rules of the master key's backup.
* Ambari's default `admin` / `admin` never reaches the Route: the server replaces it with the
  `adminPassword` Secret before the pod is Ready, and the chart does not render without one unless
  `adminPassword.allowDefault` says otherwise. For the few seconds between the server starting and
  the password changing, the server is reachable only on the pod's own address, from inside the
  cluster; a NetworkPolicy that admits only the router closes that too.
* The password reaches the server's API on the pod's loopback and is kept off the command lines and
  out of the logs; the server process itself is not given it.
