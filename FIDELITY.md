# FIDELITY.md — where the emulator lied to you

For each behaviour LocalStack did **not** reproduce faithfully: how you detected
it, and what you'd have to verify in a real AWS account before trusting it. This
is the most transferable thing in the lab — not trusting your test environment is
a senior skill. Fill each with a real detection method, not a guess.

Starters you will hit (verify each yourself, do not just copy):

- only the `default` security group is honoured; custom SGs govern nothing
- SG ingress rules apply only at instance creation
- IMDS has no `iam/security-credentials/` endpoint
- **ELBv2 (ALB) is not on the LocalStack Hobby license** — apply 501s with
  `InternalFailure`; app traffic uses EC2 `public_ip` instead
- `storage_encrypted` on RDS is returned as configured but not applied
- the Docker socket is mounted inside the EC2 "instance" (sibling container)
- ELBv2 health checking is undocumented; the listener port round-trips oddly
- declared instance classes (`db.t3.micro`, `t3.small`) are IaC only — LocalStack
  does not enforce vCPU/RAM; the Codespace is the real hardware

## RDS `aws_db_instance` is unlicensed on LocalStack Hobby (501)

- **What LocalStack did:** `tflocal apply` of `aws_db_instance.mysql` returned HTTP `501` — RDS is not in the Hobby license. The API accepted the resource in config/plan but refused to create it. `storage_encrypted` was also only echoed, never enforced.
- **How I detected it:** CI / `make up` failed on the data module with `501` from the LocalStack RDS API. Confirmed by removing `aws_db_instance` and seeing apply proceed past RDS.
- **What I'd verify on real AWS:** `CreateDBInstance` succeeds, storage encryption is actually on (`aws rds describe-db-instances` → `StorageEncrypted: true`), and the instance is not publicly accessible. In this lab MySQL is Aiven; Secrets Manager still holds the same six-key envelope so the app path matches real AWS.

## ELBv2 (ALB) is unlicensed on LocalStack Hobby (501)

- **What LocalStack did:** `tflocal apply` of `aws_lb`, `aws_lb_target_group` and `aws_lb_listener` returned HTTP `501` `InternalFailure`: *"the elbv2 service is not included within your LocalStack license"*. Same class as RDS, and it surfaced in the **same apply** — `DescribeLoadBalancers` and `DescribeTargetGroups` both 501'd after the security group had already been created successfully.
- **How I detected it:** CI run on PR #3. The apply log showed `module.data.aws_secretsmanager_secret.db` and `module.service.aws_security_group.app` completing, then three 501s in a row for the ELBv2 resources. Confirmed it was licensing rather than config by noting the free-tier resources in the same plan applied fine.
- **What I'd verify on real AWS:** the listener actually terminates TLS (LocalStack accepts a stub ACM ARN and never validates it), the target group's `/readyz` health check genuinely pulls unhealthy targets from rotation, and the listener port does not drift on re-plan. The module keeps the `aws_lb` blocks behind `enable_alb` so trivy still scans them as IaC.

## Terraform cannot create an instance from a custom Docker AMI when `root_block_device` is set

- **What LocalStack did:** `tflocal apply` failed on `aws_instance` with `collecting instance settings: couldn't find resource`, even though the image was correctly tagged `localstack-ec2/app:ami-<12hex>`, `/var/run/docker.sock` was mounted into the LocalStack container, the pro image was running, and `/_localstack/health` reported `"ec2": "available"`. The AWS provider issues `DescribeImages` **before create** whenever `root_block_device` is present, and LocalStack's `DescribeImages` never lists docker-tagged AMIs — while `RunInstances` resolves them perfectly well.
- **How I detected it:** ruled out every documented requirement one at a time via a diagnostic CI step — image present on the daemon, `localstack/localstack-pro:latest` running, socket mounted at `/var/run/docker.sock`, `EC2_VM_MANAGER=docker` set. All passed, and `describe-images --image-ids ami-<12hex>` still returned `InvalidAMIID.NotFound` while LocalStack served its stock `amzn2-ami-ecs-*` catalogue. The distinction between the two API calls was confirmed against another group's `TF_LOG=DEBUG` trace of the same failure.
- **What I'd verify on real AWS:** that the AMI id resolves through `DescribeImages` at all (on AWS it does, so this pre-check is invisible), that `root_block_device` is genuinely encrypted (`aws ec2 describe-volumes` → `Encrypted: true`), and that the instance boots the intended image. **Our pipeline works around it** by falling back to mock EC2 and running the scanned image on the runner — so "the app runs on EC2" is IaC-true but not runtime-true here.

## The S3 backend ignores `tflocal` and talks to real AWS

- **What LocalStack did:** nothing — this one is a `tflocal` gap, not an emulator lie, and worth recording because it costs an hour. `tflocal` rewrites the **provider** to point at LocalStack but leaves the **backend** addressing real AWS. `tflocal init` therefore died with `validating provider credentials: retrieving caller identity from STS ... InvalidClientTokenId`, i.e. it tried to validate `AWS_ACCESS_KEY_ID=test` against the genuine AWS STS endpoint.
- **How I detected it:** the error names STS, which nothing in the stack should be calling. Fixed by giving the backend explicit `endpoints = { s3, dynamodb, sts, iam }` pointing at `localhost:4566` plus `skip_credentials_validation`. A second symptom followed: `PutObject` returned `NoSuchBucket` for a bucket that demonstrably existed, because `bootstrap/tfstate.sh` creates it path-style via `awslocal` while the backend addressed it virtual-host style — fixed with `use_path_style = true`.
- **What I'd verify on real AWS:** none of these overrides should be present at all. On real AWS the backend needs no `endpoints` block, credential validation must stay **on**, and path-style addressing is deprecated. Every one of these five settings in `backend.hcl` is LocalStack-only scaffolding.

## The AMI id and the Docker tag are different identifiers

- **What LocalStack did:** rejected `ami = "localstack-ec2/app:ami-73f262c42ea5"` with `InvalidAMIID.Malformed: Invalid id ... (expecting "ami-...")`. The `localstack-ec2/<name>:<ami-id>` string is the **Docker tag** LocalStack discovers the image by; `aws_instance.ami` wants only the bare `ami-<hex>` id.
- **How I detected it:** the error names the exact rejected string. The brief and the module's own variable description both document `app_ami_id` as taking the full tag form, which is wrong — CI now emits both `ami_tag` (for `docker build` and the trivy image scan) and `ami_id` (for `TF_VAR_app_ami_id`).
- **What I'd verify on real AWS:** irrelevant — there is no Docker-image-as-AMI concept on AWS. A real AMI id comes from `DescribeImages` or an image build pipeline (EC2 Image Builder / Packer), so this whole tag convention is an emulator artefact that disappears on transfer.

## Not an emulator lie, but it will break your CI: free-tier Aiven powers off

- **What happened:** MySQL moved to Aiven because RDS is unlicensed. After roughly two days idle, the free service **powered off**, and Aiven withdrew its DNS record — `nslookup` and `dig @1.1.1.1` both returned `NXDOMAIN` while `aivencloud.com` itself resolved fine. `make up` then failed at the seed step.
- **How I detected it:** the failure looked like a code regression, since `make up` had passed two days earlier with an unchanged Makefile. Resolving the hostname from two independent resolvers proved the service, not the pipeline, was gone. A *sleeping* service still resolves; NXDOMAIN means the record is withdrawn. Powering it back on in the console restored the identical host, port and credentials — no secret rotation needed.
- **What I'd verify on real AWS:** RDS does not power itself off, so this failure mode does not transfer. It does mean any grader or reviewer re-running this pipeline after a quiet weekend must wake the Aiven service first — the pipeline is only as available as its cheapest dependency.
