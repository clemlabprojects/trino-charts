# Running Ambari as the KDPS operator

This is the operator's guide to the `ambari` chart: what you have to create before the first sync,
what must never change afterwards, and what to do when something breaks. It assumes Argo CD deploys
the chart and that you are running on OpenShift.

For what the chart *is* and every value it takes, see [README.md](README.md).

---

## 1. What you create before the first install

The chart creates no secrets of its own. That is deliberate: a value the chart generated would be
re-generated on the next Argo CD sync, and two of these three cannot change without losing data.

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

The schema is loaded automatically on first start, but only when the database is completely empty.

### 1.3 The certificates

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

### 1.4 If you use Vault

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

First start takes a few minutes: the schema is created and the views are extracted.

Sign in with `admin` / `admin` and **change it immediately** — it is the default and it is public.

### Pointing the view at a cluster

* **OpenShift** — KDPS → Configuration → log in with the API URL and an account that can deploy.
  Held in the Ambari database, so it survives restarts and upgrades.
* **Kubernetes** — KDPS → Configuration → upload a kubeconfig. That is a file under
  `/var/lib/ambari-server`, encrypted with the master key, and it needs `persistence.enabled=true`.

---

## 3. What must not change

| | Why |
| --- | --- |
| the master key | everything encrypted with it becomes unreadable, including the uploaded kubeconfig |
| the database | it is all of Ambari's state; the pod holds nothing else of value |
| the PVC | it holds the uploaded kubeconfig. It is annotated `helm.sh/resource-policy: keep`, so `helm uninstall` leaves it behind on purpose |

Safe to change at any time: the image tag, the certificates, the route host, resources, replicas
(keep it at 1 — the chart uses the `Recreate` strategy and a `ReadWriteOnce` claim).

---

## 4. Upgrading

Change `image.tag` and let Argo CD sync. The pod is replaced; stacks, view jars and the rest of
`/var/lib/ambari-server` come from the new image, which is why only the view's working directory is
persisted rather than the whole directory.

Take a database backup first. Ambari migrates its own schema on start-up, and that is not reversible
by rolling the image tag back.

---

## 5. When it does not work

**No pod at all, and nothing in the events for it.**
Look at the Deployment, not the pod. `ReplicaSetCreateError ... pod security enforce level that is
lower than privileged` means the namespace label from §1.4 is missing.

**`AMBARI_SECURITY_MASTER_KEY is not set: the master key is required.`**
The Secret named in `masterKey.existingSecret` does not exist, or the key inside it is not the one
in `masterKey.existingSecretKey`.

**CrashLoopBackOff, and the pod logs end with the server's own log.**
The entrypoint prints the last 200 lines of `ambari-server.log` when a start fails, precisely
because the container is about to take that file with it. Read from the bottom.

**Route answers 503.**
The router cannot reach the server. Usually the Route and the server disagree about TLS — but the
chart rejects that combination at template time, so check the pod is `Ready` first.

**Login page loads, KDPS tab is empty.**
The view is installed but not configured. KDPS → Configuration.

**`Master key initialization failed` in the server log.**
The master key is not reaching the server. Anything the view encrypts from here on uses the
fallback passphrase, so fix it before uploading a kubeconfig.

### Reading the logs

```
oc -n kdps logs deploy/ambari -c ambari                  # entrypoint + server
oc -n kdps logs deploy/ambari -c https-keystore          # the certificate conversion
oc -n kdps exec deploy/ambari -- tail -100 /var/log/ambari-server/ambari-server.log
```

---

## 6. Backup and restore

What you need to be able to restore:

1. **The database** — everything Ambari knows. `pg_dump` on your own schedule.
2. **The master key** — without it the backup is unreadable.
3. **The kubeconfig**, if you uploaded one. Or just upload it again; it is not the source of truth.

To restore: recreate the master key Secret with the *same* key, restore the database, install the
chart pointing at it. The server finds the schema present and starts against it.

---

## 7. Notes on the security posture

* The server runs as an arbitrary non-root UID under `restricted-v2`. No added SCC, no privileged
  container, no `runAsUser`.
* There are no Ambari agents, so `agent.enabled` is off. That removes the agent SSL listeners and
  the certificate authority Ambari would otherwise generate for them. Turn it on only if this
  server also manages Ambari agents — it brings the keystore requirements back with it.
* With `api.tls.enabled` there is no plain HTTP listener at all: the client connector is one or the
  other, never both.
* The keystore password is generated per pod and never leaves the pod's own `emptyDir`.
* `admin`/`admin` is the shipped default. Change it.
