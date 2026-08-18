# Terraform layout (group platform)

This directory is **conventions only** in PR-D. Resource modules land in
later PRs — do not copy-paste `aws_db_instance` / `aws_instance` into an env.

| Path | Owner | PR |
|---|---|---|
| `modules/data/` | Saloi | PR-A — RDS MySQL 8.0 + Secrets Manager |
| `modules/service/` | Berissa | PR-B — EC2 + SG (ALB removed; ELBv2 not on LocalStack Hobby) |
| `envs/_template/` | Yordanos | this PR — copy to `envs/<you>/` |
| `backend.example.hcl` | Yordanos | this PR — S3 + DynamoDB lock |

## After PR-A and PR-B merge

```bash
cp -R terraform/envs/_template terraform/envs/$USER
# edit terraform/envs/$USER/backend.hcl key = "envs/<you>/terraform.tfstate"
make up TF_WHO=$USER
```

Individual roots compose the two modules. No resource blocks in `envs/`.
