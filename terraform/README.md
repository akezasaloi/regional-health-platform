# Terraform layout (group platform)

This directory holds the shared modules and env conventions. Do not copy-paste
`aws_db_instance` / `aws_instance` into an env — compose the modules instead.

| Path | Owner | What |
|---|---|---|
| `modules/data/` | Saloi | Secrets Manager envelope around Aiven MySQL (no RDS; LocalStack Hobby returns 501) |
| `modules/service/` | Berissa | EC2 + SG (ALB removed; ELBv2 not on LocalStack Hobby) |
| `envs/_template/` | Yordanos | Copy to `envs/<you>/` |
| `backend.example.hcl` | Yordanos | S3 + DynamoDB lock |

## After the modules exist

```bash
cp -R terraform/envs/_template terraform/envs/$USER
# edit terraform/envs/$USER/backend.hcl key = "envs/<you>/terraform.tfstate"
make up TF_WHO=$USER
```

Individual roots compose the two modules. No resource blocks in `envs/`.
