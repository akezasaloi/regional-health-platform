# Terraform layout (group platform)

This directory holds the shared modules and env conventions. Do not copy-paste
`aws_db_instance` / `aws_instance` into an env — compose the modules instead.

| Path | Owner | What |
|---|---|---|
| `modules/data/` | Saloi | Secrets Manager envelope around Aiven MySQL (no RDS; LocalStack Hobby returns 501) |
| `modules/service/` | Berissa | EC2 + SG (ALB removed; ELBv2 not on LocalStack Hobby) |
| `envs/_template/` | Yordanos | Copy to `envs/<you>/`; passes Aiven vars into `module.data` |
| `backend.example.hcl` | Yordanos | S3 + DynamoDB lock |

## After the modules exist

```bash
export AIVEN_HOST=… AIVEN_PORT=… AIVEN_PASSWORD=…
export AIVEN_USER=avnadmin AIVEN_DB=capacity_lab
export AIVEN_CA_PATH=./secrets/aiven-ca.pem   # downloaded from Aiven; gitignored

cp -R terraform/envs/_template terraform/envs/$USER
# edit terraform/envs/$USER/backend.hcl key = "envs/<you>/terraform.tfstate"
make up TF_WHO=$USER
```

`make up` maps `AIVEN_*` → `TF_VAR_db_*` so passwords never live in `terraform.tfvars`.
Individual roots compose the two modules. No resource blocks in `envs/`.
