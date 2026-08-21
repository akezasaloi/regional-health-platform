# Remote state for envs/arsema. Bucket + lock table are created by
# bootstrap/tfstate.sh. State holds the Aiven password in cleartext, so the
# bucket is versioned, encrypted and never public.
bucket         = "tfstate-regional-health"
key            = "envs/arsema/terraform.tfstate"
region         = "us-east-1"
dynamodb_table = "tfstate-lock"
encrypt        = true

# tflocal rewrites the *provider* to talk to LocalStack but leaves the *backend*
# pointed at real AWS — init then dies validating "test" against the real STS
# (InvalidClientTokenId). Point the backend at LocalStack and skip the
# credential round-trips, which have no meaning here. use_path_style matters
# because bootstrap/tfstate.sh creates the bucket path-style via awslocal.
use_path_style              = true
skip_credentials_validation = true
skip_metadata_api_check     = true
skip_region_validation      = true
skip_requesting_account_id  = true

endpoints = {
  s3       = "http://localhost:4566"
  dynamodb = "http://localhost:4566"
  sts      = "http://localhost:4566"
  iam      = "http://localhost:4566"
}
