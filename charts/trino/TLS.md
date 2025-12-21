+# Trino Helm Chart (Clemlab extensions)
+
+## HTTPS keystore options
+- Default (legacy): `server.config.https.enabled=true` renders the keystore password into `config.properties` (from `additionalConfigProperties`).
+- Secret-driven (recommended): set
+  - `server.config.https.keystore.secretName`
+  - `server.config.https.keystore.key` (default `keystore.p12`)
+  - `server.config.https.keystore.mountPath` (default `/etc/trino/https-keystore.p12`)
+  - `server.config.https.keystore.passwordSecretName` (separate Secret just for the password)
+  - `server.config.https.keystore.passwordKey` (default `truststore.password`)
+  - `server.config.https.keystore.passwordMountPath` (default `/etc/trino/https-pass/password`)
+
+When both secret names are provided and HTTPS is enabled, the chart:
+- Mounts the keystore Secret and the password Secret as files (coordinator and worker).
+- Runs an initContainer to copy the ConfigMap to an emptyDir and append `http-server.https.keystore.key=$(cat password-file)` to `config.properties` so the password never lives in the ConfigMap.
+- Mounts the merged config and keystore into the pods.
+
+## Truststore
+- `global.security.tls.*` mounts a single truststore Secret (combined company CA + internal CA when provided by the Ambari backend). Defaults remain unchanged and continue to use the same Secret for truststore + password.
+
+## Notes
+- If Secret fields are empty, chart behaves as upstream (configmap mount, password must be set in `additionalConfigProperties`).
+- Passwords come from Secret files, not env vars, in the Secret-driven mode.
+- Vault/external-secrets can be used to supply the Secrets; only the Secret names/keys need to be set.

### HTTPS keystore mounting (coordinator & worker)

If you set:

```yaml
server:
  config:
    https:
      enabled: true
      port: 8443
      keystore:
        secretName: trino-https            # Secret with the keystore binary + ca.crt/tls.crt/tls.key
        key: keystore.p12                  # Data key inside that Secret
        mountPath: /etc/trino/https-keystore.p12
        passwordSecretName: trino-https-pass  # Secret with the keystore password
        passwordKey: truststore.password      # Data key inside the password Secret
        passwordMountPath: /etc/trino/https-pass/password
```