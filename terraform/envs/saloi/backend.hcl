# Bucket + lock table are created by bootstrap/tfstate.sh (Hobby LocalStack).
# Treat this state as a credential store: versioned, SSE-S3, not public.

bucket         = "tfstate-regional-health"
key            = "envs/saloi/terraform.tfstate"
region         = "us-east-1"
dynamodb_table = "tfstate-lock"
encrypt        = true
