# template-terraform-aws-fargate

A **GitHub template repository** — the infrastructure-as-code archetype for provisioning secure, observable AWS infrastructure for containerised web applications.

When used with the **workshop-platform-eng** provisioning workflow:

1. The platform creates a new repository from this template, named `{app-name}-infra`.
2. The platform runs `terraform plan` and `terraform apply` against this infrastructure code.
3. The provisioned infrastructure (Fargate tasks, VPC, ALB, autoscale, etc.) is deployed across `dev`, `staging`, `prod` environments.

---

## Infrastructure Architecture

| Component | Description | Environment-Specific |
|-----------|-------------|----------------------|
| **ECS Cluster** | Fargate launch type with Container Insights | Container Insights enabled in all envs |
| **ECS Service** | Desired task count, deployment controller | Rolling (dev) / CodeDeploy B/G (staging, prod) |
| **Task Definition** | CPU/memory, container image, X-Ray sidecar | CPU/mem sized per environment |
| **Application Load Balancer** | HTTP/HTTPS, health checks | Internet-facing (dev) / Internal (staging, prod) |
| **Auto Scaling** | CPU + memory target-tracking policies | Disabled (dev) / 1–3 (staging) / 3–10 (prod) |
| **VPC** | Isolated per-environment CIDR blocks | 10.10/20/30.0.0/16 per env |
| **Subnets** | Private (ECS) + Public (NAT, dev ALB) | 2 AZs per env |
| **NAT Gateway** | Outbound internet for ECS tasks (ECR, AWS APIs) | 1 (dev/staging) / 1-per-AZ (prod) |
| **Security Groups** | ALB → App least-privilege ingress | ALB open to internet (dev only) |
| **Route 53 Private Zone** | Internal DNS for service discovery | Per-environment zone |
| **VPC Flow Logs** | Traffic diagnostics to CloudWatch | All envs |
| **CloudWatch Log Groups** | ECS container logs + X-Ray daemon logs | Retention: 30/60/90 days per env |
| **CloudWatch Alarms** | CPU high, memory high, task count low | All envs |
| **AWS X-Ray** | Distributed tracing with sampling rule | Sampling: 100% / 10% / 1% per env |
| **IAM Task Roles** | Least-privilege execution + task roles | Per-environment resource scoping |
| **CodeDeploy** | Blue/green traffic shifting | Disabled (dev) / Linear 10% (staging) / Linear 50% (prod) |
| **Resource Groups** | Tag-based grouping of all resources | One per env, plus one for state backend |

---

## Resource Groups

Every provisioned resource is reachable through a tag-based AWS Resource Group:

| Group | Contains | Created by |
|-------|----------|------------|
| `rg-<app_name>-<env>` | All resources for one environment — ECS, ALB, VPC, IAM, logs, alarms | Terraform, in this repo (per environment) |
| `rg-<app_name>-tfstate` | The Terraform state S3 bucket | Bootstrap script in **workshop-platform-eng** |

The state bucket sits in its own group rather than an environment group for two
reasons: one bucket serves every environment (one state key each), so it carries
no `environment` tag to match on; and it must exist *before* Terraform runs —
it is the backend — so nothing in this repo can own it. See
[Step 1](#step-1--bootstrap-state-bucket-one-time-per-appaccount) for where that
script lives and why.

Group membership is resolved by tag query, so any resource carrying the matching
tags appears automatically:

- Environment groups match `application` + `environment` + `platform`
- The tfstate group matches `application` + `managed-by=bootstrap-tfstate`

---

## Module Structure

```text
terraform/
├── environments/
│   ├── dev/           # Development: small task, public ALB, fixed 1 task, 30-day logs
│   ├── staging/       # Staging: medium task, internal ALB, autoscale 1–3, 60-day logs
│   └── prod/          # Production: large task, internal ALB, autoscale 3–10, 90-day logs
│
└── modules/
    ├── monitoring/    # CloudWatch log groups, X-Ray sampling rule, CloudWatch alarms
    ├── networking/    # VPC, subnets, NAT GW, security groups, Route 53, flow logs
    └── webapp/        # ECS cluster/service, ALB, IAM roles, autoscaling, CodeDeploy

scripts/
└── verify.sh              # Post-apply control-plane verification (see below)
```

State-backend bootstrap is not here — it lives in **workshop-platform-eng** as a
cross-cutting platform concern. See [Step 1](#step-1--bootstrap-state-bucket-one-time-per-appaccount).

---

## Verification

This template owns its own post-apply verification at the canonical path
`scripts/verify.sh`. After `terraform apply`, the **workshop-platform-eng**
orchestrator checks out the generated `{app-name}-infra` repository and runs
this script, then surfaces the pass/fail counts. Because the assertions live
next to the Terraform that defines the expectations, the orchestrator stays
template-agnostic: any infra template that exposes `scripts/verify.sh` plugs
in without changing the platform.

### Script contract

| Variable | Required | Purpose |
|----------|----------|---------|
| `APP_NAME` | yes | Application name — the resource name prefix |
| `ENVIRONMENT` | yes | `dev`, `staging`, or `prod` |
| `AWS_REGION` | yes | Region the stack was applied to |
| `MAIN_DOMAIN` | no | Root domain in Route 53. Adds certificate, DNS and HTTPS reachability checks |
| `GITHUB_STEP_SUMMARY` | no | Appended with a markdown summary |
| `VERIFY_SUMMARY_FILE` | no | Machine-readable summary path (default `/tmp/verify-summary.txt`) |

| Exit | Meaning |
|------|---------|
| `0` | Every check passed |
| `1` | Checks ran, at least one failed |
| `2` | Invalid invocation — a required variable is missing, or `ENVIRONMENT` is not one of `dev`/`staging`/`prod`. No checks ran. |

**Every exit path writes the summary file** (and the markdown summary when
`GITHUB_STEP_SUMMARY` is set), exit `2` included. A caller can always parse
`VERIFY_SUMMARY_FILE` and never has to distinguish "checks failed" from "the script
never started". Invalid invocations report *all* problems at once rather than
aborting on the first, so a caller missing two variables learns about both in one
run.

`AWS_REGION` is required with **no fallback** to `AWS_DEFAULT_REGION` or the ambient
profile region. Almost every AWS API this script calls is regional, so an implicit
region reports "missing" for a stack that is deployed and healthy somewhere else —
the same reasoning that makes Terraform's `aws_region` a required input with no
default. Callers must pass it explicitly.

To run it locally against a deployed environment (an active AWS session is required):

```bash
APP_NAME=<app> ENVIRONMENT=<env> AWS_REGION=<region> MAIN_DOMAIN=<domain> bash scripts/verify.sh
```

---

## Environment-Specific Baselines

Every row below genuinely differs by environment. Settings that are identical
everywhere — TLS policy, tagging, encryption — are documented once under
[Security & Compliance](#security--compliance) rather than repeated per column.

| | `dev` | `staging` | `prod` |
|---|---|---|---|
| **Compute** | 0.25 vCPU / 512 MiB | 0.5 vCPU / 1024 MiB | 1 vCPU / 2048 MiB |
| **Instances** | 1 fixed task, no autoscaling | Autoscale 1–3 | Autoscale 3–10 (min 3 for cross-AZ spread) |
| **Availability** | Single AZ preferred, single NAT GW | Multi-AZ, 2 private subnets | Multi-AZ, NAT GW per AZ |
| **ALB** | Internet-facing — public access for CI smoke tests | Internal (private subnets) | Internal, deletion protection enabled |
| **VPC CIDR** | `10.10.0.0/16` | `10.20.0.0/16` | `10.30.0.0/16` |
| **Log retention** | 30 days | 60 days | 90 days |
| **X-Ray sampling** | 100% — full capture while developing | 10% | 1% — low overhead at production volume |
| **Deployment** | Rolling update, no CodeDeploy | CodeDeploy blue/green, linear 10% | CodeDeploy blue/green, linear 50%, auto-rollback |
| **Checkov baseline** | `.checkov.nonprod.yaml` (relaxed) | `.checkov.nonprod.yaml` (relaxed) | `.checkov.yaml` (strict) |

---

## Security & Compliance

### Network Isolation

- **Egress**: ECS tasks restricted to HTTPS (443) and DNS (53) outbound via security group
- **Inbound**: ALB is internal in staging/prod; dev ALB is internet-facing for CI access
- **Flow Logs**: VPC traffic logged to CloudWatch for compliance audit trails

### Identity & Access

- **Task Execution Role**: `AmazonECSTaskExecutionRolePolicy` + scoped Secrets Manager access for container secret injection
- **Task Role**: Least-privilege — Secrets Manager read (`secretsmanager:GetSecretValue`) scoped to `{prefix}/*`, X-Ray write (when enabled)
- **ECR Pull**: Via IAM task execution role (no registry credentials in task definitions or app settings)
- **TLS**: TLS 1.3 only in all environments (`ELBSecurityPolicy-TLS13-1-3-2021-06`), enforced by a validation block on the module variable so it cannot be weakened per environment; a valid ACM certificate ARN is required

### Compliance

- **Checkov**: Infrastructure security policy enforcement with environment-specific baselines (prod strict, dev/staging relaxed)
- **Logging**: ECS container logs → CloudWatch; VPC flow logs → CloudWatch
- **X-Ray**: End-to-end distributed tracing with environment-appropriate sampling rates

---

## Customization

### App Settings

App-specific environment variables are passed via `app_settings` map in each environment's `.tfvars`. Example:

```hcl
app_settings = {
  DATABASE_URL = "postgresql://..."
  API_KEY      = "..."
}
```

### Secrets Manager Integration

Reference AWS Secrets Manager secrets in the task definition (injected at task launch, never in plaintext):

```hcl
# In the webapp module call:
secrets_manager_arns = {
  DB_PASSWORD = "arn:aws:secretsmanager:us-east-1:123456789012:secret:myapp/db-password-AbCdEf"
  API_KEY     = "arn:aws:secretsmanager:us-east-1:123456789012:secret:myapp/api-key-XyZwVu"
}
```

### Container Registry

Pull images from ECR (private) or a public registry. ECR pull uses IAM roles — no credentials needed:

```hcl
container_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/myapp:v1.2.3"
```

For public registries (Docker Hub, ECR Public):

```hcl
container_image = "public.ecr.aws/nginx/nginx:stable-alpine"
```

### Custom Domain

Set `main_domain` to the root domain managed in Route 53. The networking module automatically:

1. Derives the FQDN as `<app_name>.<environment>.<main_domain>` (e.g. `myapp.dev.example.com`)
2. Looks up the matching public hosted zone by name
3. Issues a DNS-validated ACM certificate and creates the Route 53 validation record
4. Passes the validated certificate ARN to the ALB HTTPS listener

```hcl
# terraform.tfvars
main_domain = "example.com"
# Results in: myapp.dev.example.com (dev), myapp.staging.example.com (staging), myapp.prod.example.com (prod)
```

The `tofu apply` blocks until ACM reports the certificate as `ISSUED` (typically under a minute via Route 53 DNS validation). The public hosted zone for `main_domain` must exist in the same AWS account.

---

## Local End-to-End Test

This section mirrors the steps the **workshop-platform-eng** provisioning workflow executes in CI. Run them locally to validate changes before pushing.

### Prerequisites

| Tool | Install |
|------|---------|
| AWS CLI v2 | `brew install awscli` |
| OpenTofu | `brew install opentofu` |
| Checkov | `pip install checkov` |
| jq | `brew install jq` |

**AWS access**: credentials must be active before running any `tofu` command. The provider reads from the standard AWS credential chain (`default` profile, `AWS_PROFILE` env var, `~/.aws/credentials`). Verify your session is valid before proceeding:

```bash
aws sts get-caller-identity
```

**Container image**: the ECS service needs a reachable image. Use a public placeholder for initial validation:

```bash
CONTAINER_IMAGE="public.ecr.aws/nginx/nginx:stable-alpine"
```

---

### Step 1 — Bootstrap state bucket (one-time per app/account)

**This step does not run from this repository.** The state-backend bootstrap script
lives in **workshop-platform-eng**. Run it from a
checkout of that repo:

```bash
cd /path/to/workshop-platform-eng
./scripts/bootstrap-tfstate.sh --app-name myapp --aws-region eu-west-1
```

Outputs `TFSTATE_BUCKET` (e.g. `tf-state-myapp-12345678`) and `TFSTATE_REGION` (e.g. `eu-west-1`). Store these for the init step.

State bootstrap is a **cross-cutting platform concern, not a per-template
responsibility**. The backend has to exist before any template can `init`, one
bucket serves every environment of an application, and the same bootstrap applies
across cloud targets — so the orchestrator owns it once instead of each
infrastructure template shipping and maintaining its own near-duplicate copy.

### Step 2 — Security scan (Checkov)

Run Checkov before `tofu plan` to catch policy violations early. Use the environment-appropriate config:

```bash
# dev or staging
checkov -d terraform/ --config-file .checkov.nonprod.yaml

# prod
checkov -d terraform/ --config-file .checkov.yaml
```

All checks must pass (zero failures) before proceeding.

### Step 3 — Init

The `-backend-config="region=..."` flag here sets the **S3 bucket region** (where the Terraform state file is stored). It does **not** control where AWS resources are deployed — that is `aws_region` in the next step.

```bash
export AWS_REGION=eu-west-1
export APP_NAME=myapp
export MAIN_DOMAIN=example.com
export ENVIRONMENT=dev
tofu -chdir=terraform/environments/$ENVIRONMENT init \
  -backend-config="bucket=$TFSTATE_BUCKET" \
  -backend-config="key=$ENVIRONMENT/terraform.tfstate" \
  -backend-config="region=$TFSTATE_REGION"
```

### Step 4 — Plan

`aws_region` is required and has no default. Omitting it is an error — OpenTofu will stop and ask. Pass it explicitly every time to prevent accidental cross-region deployments. Typically, it will be the same as the region used to create the S3 backend bucket.

```bash
tofu -chdir=terraform/environments/$ENVIRONMENT plan \
  -var="aws_region=$AWS_REGION" \
  -var="app_name=$APP_NAME" \
  -var="container_image=public.ecr.aws/nginx/nginx:stable-alpine" \
  -var="container_port=80" \
  -var="health_check_path=/" \
  -var="main_domain=$MAIN_DOMAIN" \
  -out=tfplan
```

The `container_port` (default `8080`) and `health_check_path` (default `/health`) override above match the nginx placeholder image. Replace with your application's actual values for a real deployment.

The ACM certificate (e.g., `myapp.dev.example.com`) is issued and DNS-validated automatically during apply. The public hosted zone for `main_domain` must exist in the same AWS account.

Review the plan output before applying.

### Step 5 — Apply

```bash
tofu -chdir=terraform/environments/$ENVIRONMENT apply tfplan
```

### Step 6 — Verify

```bash
AWS_REGION=$AWS_REGION APP_NAME=$APP_NAME ENVIRONMENT=$ENVIRONMENT MAIN_DOMAIN=$MAIN_DOMAIN bash scripts/verify.sh
```

Exits 0 if all assertions pass. A summary is written to `/tmp/verify-summary.txt`.

`MAIN_DOMAIN` is optional. When set, the script adds an end-to-end HTTPS check against `<app>.<env>.<domain>` — but only for internet-facing environments (dev). Staging and prod use an internal ALB so no public DNS check runs regardless of `MAIN_DOMAIN`.

### Step 7 — Destroy (teardown)

```bash
tofu -chdir=terraform/environments/$ENVIRONMENT destroy \
  -var="aws_region=$AWS_REGION" \
  -var="app_name=$APP_NAME" \
  -var="container_image=public.ecr.aws/nginx/nginx:stable-alpine" \
  -var="container_port=80" \
  -var="health_check_path=/" \
  -var="main_domain=$MAIN_DOMAIN"
```

---

## License

[MIT](LICENSE) — see the license file for details.
