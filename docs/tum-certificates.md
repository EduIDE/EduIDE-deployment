# TUM Certificate Process

This guide explains the TUM-specific process for obtaining and configuring wildcard SSL certificates for Theia Cloud deployments.

## Overview

Theia Cloud creates dynamic URIs for each session-plugin combination, requiring wildcard SSL certificates. At TUM, those wildcard certificates are externally signed by RBG and have specific requirements:

- Wildcard certificates cannot be automatically renewed via cert-manager
- Certificates must be requested through a specific approval process
- Certificates are issued by Harica (TUM's certificate authority)

## Why Wildcard Certificates?

Each Theia session creates unique subdomains for isolation and security:

```
https://random-id.webview.instance.test1.theia-test.artemis.cit.tum.de
https://another-id.webview.instance.test1.theia-test.artemis.cit.tum.de
...
```

A wildcard certificate for `*.webview.instance.test1.theia-test.artemis.cit.tum.de` covers all these dynamic subdomains.

## Required Wildcard Patterns

You need wildcard certificates for the following patterns based on your environment:

| Environment | Wildcard Certificate Required |
|------------|-------------------------------|
| **Production** | `*.webview.instance.theia.artemis.cit.tum.de` |
| **Staging** | `*.webview.instance.theia-staging.artemis.cit.tum.de` |
| **Test1** | `*.webview.instance.test1.theia-test.artemis.cit.tum.de` |
| **Test2** | `*.webview.instance.test2.theia-test.artemis.cit.tum.de` |

## TUM Certificate Request Process

1. Create a certificate request at cm.harica.gr
    - You need to request a wildcard certificate for the base domain you intend to use e.g. `*.theia.artemis.cit.tum.de`
    - Make sure to note down the passphrase and download the private key
2. Request Approval from RBG via mail
3. Once approved, download the certificate files from cm.harica.gr in PEM fullchain format
4. Decrypt the privatekey using the passphrase provided during request

    ```bash
    openssl rsa -in theia.artemis.cit.tum.de.key.pem -out theia.artemis.cit.tum.de.key
    ```

5. Add the certificate and key to your the github environment secrets
