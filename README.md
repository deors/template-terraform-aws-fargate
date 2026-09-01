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
| **Resource Groups** | Tag-based grouping of all resources | One per env, plus one for state backend |
| **VPC** | Isolated per-environment CIDR blocks | 10.10/20/30.0.0/16 per env |
| **Subnets** | Private (ECS) + Public (NAT, dev ALB) | 2 AZs per env |
| **NAT Gateway** | Outbound internet for ECS tasks (ECR, AWS APIs) | 1 (dev/staging) / 1-per-AZ (prod) |
| **Security Groups** | ALB → App least-privilege ingress | ALB open to internet (dev only) |
| **Route 53 DNS** | Split-horizon: app FQDN alias record for the ALB | Public zone record (dev) / VPC-private zone (staging, prod) |
| **VPC Flow Logs** | Traffic diagnostics to CloudWatch | All envs |
| **Application Load Balancer** | HTTP/HTTPS, health checks | Internet-facing (dev) / Internal (staging, prod) |
| **ECS Cluster** | Fargate launch type with Container Insights | Container Insights enabled in all envs |
| **ECS Service** | Desired task count, deployment controller | Rolling (dev) / CodeDeploy B/G (staging, prod) |
| **Task Definition** | CPU/memory, container image, X-Ray sidecar | CPU/mem sized per environment |
| **Auto Scaling** | CPU + memory target-tracking policies | Disabled (dev) / 1–3 (staging) / 3–10 (prod) |
| **CodeDeploy** | Blue/green traffic shifting | Disabled (dev) / Linear 10% (staging) / Linear 50% (prod) |
| **IAM Task Roles** | Least-privilege execution + task roles | Per-environment resource scoping |
| **CloudWatch Log Groups** | ECS container logs + X-Ray daemon logs | Retention: 30/60/90 days per env |
| **CloudWatch Alarms** | CPU high, memory high, task count low | All envs |
| **AWS X-Ray** | Distributed tracing with sampling rule | Sampling: 100% / 10% / 1% per env |

---

## Resource Groups

Every provisioned resource is reachable through a tag-based AWS Resource Group:

| Group | Contains | Created by |
|-------|----------|------------|
| `rg-<app_name>-<env>` | All resources for one environment — ECS, ALB, VPC, IAM, logs, alarms | Terraform, in this repo (per environment) |
| `rg-<app_name>-tfstate` | The Terraform state S3 bucket | Bootstrap script in **workshop-platform-eng** |

An AWS Resource Group is a **query, not a container**: membership is resolved
by tag, so any resource carrying the matching tags appears automatically, and
the group itself has no lifecycle over its members.

- Environment groups match `application` + `environment` + `platform`
- The tfstate group matches `application` + `managed-by=bootstrap-tfstate`

Practical implications:

- **Deletion**: removing resources is `tofu destroy`'s job — deleting a group
  only removes the view and never touches a resource.
- **Cost visibility**: the same tags drive per-environment spend in Cost
  Explorer — filter on `application` + `environment`. (Tags must be activated
  as cost allocation tags in the billing settings, once per account.)
- **Access control**: IAM has no resource-group scope; the tag set doubles as
  the access-control handle instead. Policies can condition on
  `aws:ResourceTag/application` and `aws:ResourceTag/environment` (ABAC) to
  grant a team access to one application's environment.

A group answers "what is in this environment?" — to see what the application
owns across environments, query the tags directly:

```bash
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=application,Values=$APP_NAME \
  --query 'ResourceTagMappingList[].ResourceARN' \
  --output table
```

The state bucket sits in its own group rather than an environment group for two
reasons: one bucket serves every environment (one state key each), so it carries
no `environment` tag to match on; and it must exist *before* Terraform runs —
it is the backend — so nothing in this repo can own it, and it must survive a
`tofu destroy` of any environment. See
[Step 1](#step-1--bootstrap-terraform-state-one-time-per-appaccount) for where that
script lives and why.

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
cross-cutting platform concern. See [Step 1](#step-1--bootstrap-terraform-state-one-time-per-appaccount).

---

## Verification

This template owns its own post-apply verification at the canonical path
`scripts/verify.sh`. After `tofu apply`, the **workshop-platform-eng**
orchestrator checks out the generated `{app-name}-infra` repository and runs
this script, then surfaces the pass/fail counts. Because the assertions live
next to the Terraform that defines the expectations, the orchestrator stays
template-agnostic: any infra template that exposes `scripts/verify.sh` plugs
in without changing the platform.

### Interface

| Variable | Required | Purpose |
|----------|----------|---------|
| `AWS_REGION` | Yes | Region where all application resources are created |
| `APP_NAME` | Yes | Application name |
| `ENVIRONMENT` | Yes | `dev`, `staging`, `prod` |
| `MAIN_DOMAIN` | No | Root domain in Route 53. Adds certificate, DNS and HTTPS reachability checks |

### Outputs

| Variable | Required | Purpose |
|----------|----------|---------|
| `GITHUB_STEP_SUMMARY` | -- | Path appended with a Markdown summary (set automatically by GitHub Actions) |
| `VERIFY_SUMMARY_FILE` | -- | Machine-readable `key=value` summary path. Defaults to `/tmp/verify-summary.txt`. |

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | Every check passed |
| `1` | Checks ran; at least one failed |
| `2` | Invalid invocation — a required variable is missing or `ENVIRONMENT` is not recognised. No checks ran. |

**Every exit path writes the summary file** (and the markdown summary when
`GITHUB_STEP_SUMMARY` is set), exit `2` included. A caller can always parse
`VERIFY_SUMMARY_FILE` and never has to distinguish "checks failed" from "the script
never started". Invalid invocations report *all* problems at once rather than
aborting on the first, so a caller missing two variables learns about both in one
run.

### What it checks

Grouped assertions: ECS cluster (status, Container Insights), ECS service
(status, running/desired counts, launch type), task definition (CPU, memory,
network mode, roles), ALB (state, scheme, type) and its HTTPS listener's TLS
policy against the TLS 1.3-only allow-list, target health, autoscaling
(staging/prod), CloudWatch logs including per-environment retention
(30/60/90 days), CloudWatch alarms (CPU, memory, task count — existence, not
state, since fresh deployments sit in `INSUFFICIENT_DATA`), X-Ray (sampling
rule, per-environment rate, daemon log group), IAM roles, CodeDeploy
(staging/prod), networking (a VPC uniquely identified by its tags, flow
logs), ACM certificate, Route 53 DNS (split-horizon aware: public record
asserted in dev; in staging/prod the private zone and record are asserted
present and the public record asserted **absent**), and the public endpoint.

All but the last are control-plane assertions. The **public endpoint** check
is the one that sends real traffic: an HTTPS `GET` against
`<app>.<env>.<domain>` expecting `200`. Because `curl` validates the
certificate chain by default, this doubles as proof the ACM certificate is
serving correctly — a TLS failure surfaces as `000`, not a status code.

That probe runs for **dev only**, whose ALB is internet-facing for exactly
this purpose. Staging and prod use an internal ALB, so a request from a
runner outside the VPC would fail on a perfectly healthy deployment; those
environments are verified through the control plane alone. The certificate,
DNS and probe groups run only when `MAIN_DOMAIN` is set — an HTTP-only
deployment without it is valid, and those groups are skipped.

### Running locally

An active AWS session is required:

```bash
AWS_REGION=<region> APP_NAME=<app> ENVIRONMENT=<env> MAIN_DOMAIN=<domain> bash scripts/verify.sh
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
| **App DNS record** | Public zone — resolvable from anywhere | VPC-private zone — resolves only inside the VPC | VPC-private zone — resolves only inside the VPC |
| **Post-apply probe** | HTTPS `GET` on the app FQDN, expects `200` | Control plane only | Control plane only |
| **Checkov baseline** | `.checkov.nonprod.yaml` (relaxed) | `.checkov.nonprod.yaml` (relaxed) | `.checkov.yaml` (strict) |

---

## Security & Compliance

### Network Isolation

- **Egress**: ECS tasks restricted to HTTPS (443) and DNS (53) outbound via security group
- **Inbound**: ALB is internal in staging/prod; dev ALB is internet-facing for CI access
- **Flow Logs**: VPC traffic logged to CloudWatch for compliance audit trails
- **DNS**: split-horizon — internal environments (staging/prod) publish their FQDN only in a VPC-private hosted zone; internal IPs never appear in public DNS. `verify.sh` asserts the public record's absence for those environments

### Identity & Access

- **Task Execution Role**: `AmazonECSTaskExecutionRolePolicy` + scoped Secrets Manager access for container secret injection
- **Task Role**: Least-privilege — Secrets Manager read (`secretsmanager:GetSecretValue`) scoped to `{prefix}/*`, X-Ray write (when enabled)
- **ECR Pull**: Via IAM task execution role (no registry credentials in the task definition or container environment)
- **TLS**: TLS 1.3 only in all environments (`ELBSecurityPolicy-TLS13-1-3-2021-06`), enforced by a validation block on the module variable so it cannot be weakened per environment; a valid ACM certificate ARN is required

### Compliance

- **Checkov**: Infrastructure security policy enforcement with environment-specific baselines (prod strict, dev/staging relaxed)
- **Logging**: ECS container logs → CloudWatch; VPC flow logs → CloudWatch
- **X-Ray**: End-to-end distributed tracing with environment-appropriate sampling rates

---

## Customization

### Container Contract

The template is built around the archetype's container contract: **port
8080, health endpoint `/health`**. `health_check_path` defaults to `/health`
and is what the load balancer health checks poll. `container_port` defaults
to `8080` and drives the task definition's port mapping, both target groups,
and the app security group's ingress rule — the only path traffic can reach
the container on, fixed at provision time.

Do not set `PORT` directly in `app_settings` — `container_port` is the
single source of truth and the template injects `PORT` from it.

### App Settings

App-specific environment variables are passed via `app_settings` map in each
environment's `.tfvars`; they become plain environment variables on the
container. Do not put secrets here — use
[Secrets Manager references](#secrets-manager-integration) instead.

The template always injects the archetype's environment-variable contract:
`PORT` (the container port), `APP_NAME`, `APP_ENV` (the environment name),
and `IMAGE_TAG` (parsed from the image reference). Applications should read
these rather than invent their own names; a key redefined in `app_settings`
overrides the injected value. Example:

```hcl
app_settings = {
  DATABASE_URL = "postgresql://..."
  API_KEY      = "..."
}
```

Terraform owns these settings only at creation: it seeds the initial set and
then ignores drift on them. From the first deployment onwards the pipeline
owns them — it restamps the identity variables on each deploy and adds new
settings as the application evolves, and a re-apply never strips them. The
flip side: changing these inputs in Terraform affects only newly created
stacks; on a running app, settings are applied through the deployment
pipeline.

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

The pull happens at runtime, by the task execution role — never by the
identity running Terraform. The auth path is selected by the image reference
itself:

| Registry | Configure | Pull authenticates as |
|---|---|---|
| Public (`public.ecr.aws`, public Docker Hub/GHCR) | `container_image` only | Anonymous — no credentials involved |
| Private ECR, same account | `container_image` only | The task execution role (`AmazonECSTaskExecutionRolePolicy`) |
| Private ECR, cross-account | `container_image`, plus a resource policy on the repository granting this account's execution role — not managed by this template | The task execution role, authorized by the repository policy |

```hcl
container_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/myapp:v1.2.3"
```

For public registries:

```hcl
container_image = "public.ecr.aws/nginx/nginx:stable-alpine"
```

Anonymous Docker Hub pulls are rate-limited per source IP, and every task in
an environment egresses through the NAT gateway address(es) — scale-outs can
hit the limit as one client. Prefer `public.ecr.aws` or an ECR mirror.

Private registries other than ECR (Docker Hub, GHCR) are **not supported** —
the task definition carries no registry credentials by design: there are no
registry credential variables, and nothing registry-related is persisted in
state. Mirror the image into ECR instead.

After first creation, CI/CD owns which image runs (the template ignores
drift on the service's task definition), so `container_image` affects only
newly created stacks; on a running app, images are rolled out through the
deployment pipeline.

### Hostnames and TLS

Set `main_domain` to the root domain managed in Route 53. The networking module automatically:

1. Derives the FQDN as `<app_name>.<environment>.<main_domain>` (e.g. `myapp.dev.example.com`)
2. Looks up the matching public hosted zone by name
3. Issues a DNS-validated ACM certificate and creates the Route 53 validation record
4. Passes the validated certificate ARN to the ALB HTTPS listener
5. Publishes the FQDN as an alias record for the ALB — **split-horizon by
   environment**: dev's record goes in the public zone (its ALB is
   internet-facing), while staging and prod publish at the apex of a
   VPC-private hosted zone named after the FQDN, so their names resolve only
   inside the VPC and internal IP addresses never appear in public DNS. A
   public record answering with RFC1918 addresses would leak internal topology
   and be dropped by resolvers with DNS-rebinding protection. Only the ACM
   validation CNAMEs stay public in every environment — ACM validates from the
   public internet, and the FQDN's existence is public anyway via Certificate
   Transparency logs; the private zone hides the addresses, not the name.

```hcl
# terraform.tfvars
main_domain = "example.com"
# Results in: myapp.dev.example.com (dev), myapp.staging.example.com (staging), myapp.prod.example.com (prod)
```

The `tofu apply` blocks until ACM reports the certificate as `ISSUED` (typically under a minute via Route 53 DNS validation). The public hosted zone for `main_domain` must exist in the same AWS account.

---

## Local End-to-End Test

This section mirrors the steps the **workshop-platform-eng** provisioning
workflow executes in CI. Run them locally to validate changes before pushing.

### Prerequisites

The following tools must be installed and on `$PATH`:

| Tool | Purpose |
|------|---------|
| [`aws`](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | AWS CLI v2 — resource queries and auth |
| [`tofu`](https://opentofu.org/docs/intro/install/) | OpenTofu — plan, apply, destroy |
| [`checkov`](https://www.checkov.io/2.Basics/Installing%20Checkov.html) | Infrastructure policy enforcement |
| [`jq`](https://jqlang.github.io/jq/) | JSON processing in `scripts/verify.sh` |

**AWS access**: credentials must be active before running any `aws` or `tofu`
command. Login and/or verify your session
before proceeding:

```bash
aws login
# and/or
aws sts get-caller-identity
```

---

### Step 1 — Bootstrap Terraform state (one-time per app/account)

> **State bootstrapping is a cross-cutting concern owned by the orchestrator, not by individual
> infrastructure templates.** The bootstrap script lives in the **workshop-platform-eng**
> repository and must be run from there. Each template is deliberately free of bootstrap logic —
> the orchestrator is the single place to update when storage naming conventions, retention
> policies, or cloud targets change.

Export shared variables first — these are reused in every subsequent command:

```bash
export AWS_REGION=eu-west-1
export APP_NAME=myapp
export ENVIRONMENT=dev
export MAIN_DOMAIN=example.com

export APP_SHORT=$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]' | tr -d '_' | cut -c1-20)
export ACCT_SHORT=$(aws sts get-caller-identity --query Account --output text | cut -c1-8)
```

From the **workshop-platform-eng** repository:

```bash
cd /path/to/workshop-platform-eng
./scripts/bootstrap-tfstate-aws.sh \
  --aws-region $AWS_REGION \
  --app-name $APP_NAME
```

Creates a dedicated AWS S3 bucket for remote state (idempotent).

### Step 2 — Security scan (Checkov)

Run Checkov before `tofu plan` to catch policy violations before any state is touched.
Each environment is scanned with its own baseline: dev and staging use the
relaxed config, prod the strict one. Checkov resolves the shared modules with
the values each environment passes in, so module code is assessed three times —
once per environment, under its real configuration.

Do **not** scan `terraform/modules` on its own: with no caller, Checkov judges
the module *defaults*, which are deliberately non-prod-shaped, and the strict
baseline fails checks that every actual deployment satisfies.

```bash
# dev
checkov -d terraform/environments/dev --config-file .checkov.nonprod.yaml

# staging
checkov -d terraform/environments/staging --config-file .checkov.nonprod.yaml

# prod
checkov -d terraform/environments/prod --config-file .checkov.yaml
```

All three scans must pass (zero failures) before proceeding. Every skip in
both config files carries a stated reason.

### Step 3 — Init

The `-backend-config="region=..."` flag here sets the **S3 bucket region**
(where the Terraform state file is stored). It does **not** control where AWS
resources are deployed — that is `aws_region` in the next step. For consistency,
the S3 bucket region is the same as the deployment region, but it does not have
to be.

```bash
tofu -chdir=terraform/environments/$ENVIRONMENT init \
  -backend-config="region=$AWS_REGION" \
  -backend-config="bucket=tf-state-${APP_SHORT}-${ACCT_SHORT}" \
  -backend-config="key=$ENVIRONMENT/terraform.tfstate"
```

### Step 4 — Plan

```bash
tofu -chdir=terraform/environments/$ENVIRONMENT plan \
  -var="aws_region=$AWS_REGION" \
  -var="main_domain=$MAIN_DOMAIN" \
  -var="app_name=$APP_NAME" \
  -var="container_image=public.ecr.aws/nginx/nginx:stable-alpine" \
  -var="container_port=80" \
  -var="health_check_path=/" \
  -out=tfplan
```

This plan for `dev` deploys a public placeholder image
(`public.ecr.aws/nginx/nginx:stable-alpine`) with `container_port = 80`
and `health_check_path = "/"`, so the template can be applied and verified end
to end before a real application image exists. Swap `container_image`,
`container_port`, and `health_check_path` for your own app's values when moving
past validation.

The ACM certificate (e.g., `myapp.dev.example.com`) is issued and DNS-validated
automatically during apply. The public hosted zone for `main_domain` must exist
in the same AWS account.

Review the plan output before applying — confirm the region for resources is the
one you intended, and that the resource count matches expectations for the
environment.

### Step 5 — Apply

```bash
tofu -chdir=terraform/environments/$ENVIRONMENT apply tfplan
```

### Step 6 — Verify

```bash
./scripts/verify.sh
```

Exits `0` if all assertions pass. A summary is written to
`/tmp/verify-summary.txt`.

`MAIN_DOMAIN` is optional. When set, the script adds an end-to-end HTTPS check
against `<app>.<env>.<domain>` — but only for `dev`; `staging` and `prod` use
the internal ALB as they are not exposed to the Internet.

### Step 7 — Destroy (teardown)

```bash
tofu -chdir=terraform/environments/$ENVIRONMENT destroy \
  -var="aws_region=$AWS_REGION" \
  -var="main_domain=$MAIN_DOMAIN" \
  -var="app_name=$APP_NAME" \
  -var="container_image=public.ecr.aws/nginx/nginx:stable-alpine" \
  -var="container_port=80" \
  -var="health_check_path=/"
```

---

## License

[MIT](LICENSE) — see the license file for details.
