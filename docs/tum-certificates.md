# TUM certificates

Two kinds of certificate, obtained two different ways.

| | How | Renewal |
|---|---|---|
| `<landing>`, `service.<landing>`, `instance.<landing>` | cert-manager, ACME HTTP-01 | automatic |
| `*.webview.instance.<landing>` | Harica via RBG, by hand | **by hand, every year** |

The first kind is derived and issued for you: `Bootstrap cluster` builds one
`Certificate` per cluster covering every environment's three non-wildcard hosts,
from the same pass that derives the Gateway listeners, so a name cannot be
missed. It needs a `ClusterIssuer` that can solve over Gateway API - see step 3
of [cluster-setup.md](cluster-setup.md).

The rest of this page is about the second kind.

## Why the wildcard cannot be automated

Every session serves its previews, rendered Markdown and embedded documentation
from its own origin, so that they cannot script against the IDE itself:

```
https://<random-id>.webview.instance.test1.eduide.student.k8s.aet.cit.tum.de
```

Those names are created at runtime, so the certificate has to be a wildcard.

**ACME does not permit HTTP-01 for wildcards.** Proving control of
`*.webview.instance.<host>` by serving a token at that exact name is impossible,
because there is no such name. This is the specification, not a cert-manager
limitation, and no configuration changes it. The alternative is a DNS-01
challenge, which needs an API credential for the zone; TUM does not hand those
out, so the certificate is bought and installed by hand.

Without it, sessions still start and the IDE still loads. **Only previews
break**, from inside the IDE, with an opaque error. That is usually found by a
student weeks after go-live rather than by whoever installed it.

## Which wildcards are needed

One per landing host, since the webview names sit two labels below it.

| Environment | Wildcard |
|---|---|
| `test1` | `*.webview.instance.test1.eduide.student.k8s.aet.cit.tum.de` |
| `test2` | `*.webview.instance.test2.eduide.student.k8s.aet.cit.tum.de` |
| `test3` | `*.webview.instance.test3.eduide.student.k8s.aet.cit.tum.de` |
| `e2e-test` | `*.webview.instance.e2e.eduide.student.k8s.aet.cit.tum.de` |
| `staging` | `*.webview.instance.staging.eduide.student.k8s.aet.cit.tum.de` |
| `tum-production` | `*.webview.instance.eduide.artemis.aet.cit.tum.de` |
| `bonn` | `*.webview.instance.bonn.eduide.aet.cit.tum.de` |
| `mannheim` | `*.webview.instance.mannheim.eduide.aet.cit.tum.de` |

In practice one certificate per cluster covers all of its environments, by
requesting a wildcard high enough in the tree. Whatever is requested must cover
every webview host on that cluster, because all of those listeners reference the
one Secret named in `spec.tls.webview`.

## Requesting one

1. Create a certificate request at [cm.harica.gr](https://cm.harica.gr) for the
   base domain, for example `*.eduide.student.k8s.aet.cit.tum.de`. Note the
   passphrase and download the private key.
2. Request approval from RBG by mail.
3. Once approved, download the certificate from cm.harica.gr in **PEM fullchain**
   format.
4. Decrypt the private key with the passphrase:

   ```bash
   openssl rsa -in eduide.student.k8s.aet.cit.tum.de.key.pem \
               -out eduide.student.k8s.aet.cit.tum.de.key
   ```

5. Check it covers what you think before installing it:

   ```bash
   openssl x509 -in fullchain.pem -noout -text | grep -A1 'Subject Alternative Name'
   openssl x509 -in fullchain.pem -noout -enddate
   ```

6. Put both files in the **cluster** GitHub Environment, as plain PEM. The
   workflow base64-encodes them itself, so do not pre-encode.

   ```bash
   REPO=EduIDE/EduIDE-deployment
   gh secret set THEIA_WILDCARD_CERTIFICATE_CERT --repo "$REPO" \
     --env cluster-tum-student < fullchain.pem
   gh secret set THEIA_WILDCARD_CERTIFICATE_KEY --repo "$REPO" \
     --env cluster-tum-student < eduide.student.k8s.aet.cit.tum.de.key
   ```

7. Re-run `Bootstrap cluster`. It writes the Secret named in
   `spec.tls.webview`, which the webview listeners reference.

## After installing it

Nothing checks that a certificate matches the hostname it serves. Gateway API
never compares the two, so a listener holding a certificate for entirely
different names reports `Programmed=True ResolvedRefs=True`.

Verify by asking the server what it presents, for a name under the wildcard:

```bash
h=probe.webview.instance.test1.eduide.student.k8s.aet.cit.tum.de
echo | openssl s_client -connect "$h:443" -servername "$h" 2>/dev/null \
  | openssl x509 -noout -checkhost "$h" -enddate
```

`Host <name> matches certificate` is the answer you want. `curl -k` will tell
you nothing, because suppressing this failure is exactly what it does.

## Track the expiry

This certificate does not renew itself and nothing warns you. When it expires,
every preview in every session on the cluster breaks at once, and the symptom
reported will be "the IDE is broken", not "a certificate expired".

Put the date somewhere the team actually looks. To read what is live:

```bash
kubectl -n eduide-system get secret static-theia-cert \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -enddate -subject
```
