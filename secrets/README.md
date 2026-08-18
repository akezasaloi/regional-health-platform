# secrets/ — do not commit

Download the Aiven MySQL **CA certificate** from the service page and save it
here as `aiven-ca.pem`. Then:

```bash
export AIVEN_CA_PATH=./secrets/aiven-ca.pem
```

`*.pem` / `*.crt` in this folder are gitignored. The password never lives here
either — only in your shell / GitHub Actions secrets.
