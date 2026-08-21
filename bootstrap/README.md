# Remote-state bootstrap

`./bootstrap/tfstate.sh` creates, on LocalStack Hobby:

- S3 bucket `tfstate-regional-health` — versioned, SSE-S3, public access blocked
- DynamoDB table `tfstate-lock`

Idempotent. Requires `LOCALSTACK_AUTH_TOKEN` and `awslocal`.
`make up` calls this after LocalStack is healthy.
