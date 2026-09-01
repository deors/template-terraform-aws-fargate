## Troubleshooting

Issues with the AWS resources this template creates. Problems with the
provisioning pipeline itself — GitHub Actions, Terraform remote state, or OIDC
login to AWS — are documented by the platform:
[workshop-platform-eng troubleshooting](https://deors.github.io/workshop-platform-eng/troubleshooting/).

### `terraform apply` hangs, then fails on the ECS service

**Symptom.** Apply sits on `aws_ecs_service.this: Still creating…` for 10–15
minutes and then fails. The service never reaches a steady state; the target
group shows targets cycling `initial` → `unhealthy` → drained.

**Cause.** `container_port` and `health_check_path` don't match what the image
actually serves. The ALB health check polls `health_check_path` on
`container_port`; when nothing answers 200 there, ECS kills the task, starts a
replacement, and the loop repeats until the service times out.

**Fix.** Set both to match the image:

```hcl
container_port    = 8080     # this template's default
health_check_path = "/health"
```

Note the defaults differ depending on how you invoke this template. The
variables here default to `8080` and `/health`, suitable for a typical
application. The platform's provisioning workflow instead defaults them to
`80` and `/`, matching the placeholder image it uses for a first apply
(`public.ecr.aws/nginx/nginx:stable-alpine`). Whichever entry point you use,
pass the values your image needs.

**This also applies to reconcile runs.** `container_image` is safe to leave at
its default on a re-run: `aws_ecs_service` declares
`lifecycle { ignore_changes = [task_definition, load_balancer, desired_count] }`,
so once CodeDeploy has deployed, Terraform stops touching the running image.
`container_port` and `health_check_path` have no such protection — they drive
the ALB target group, which nothing else owns. Re-applying with the defaults
after a real deployment will point the health check back at `/` on port 80 and
break a working service. Treat them like `aws_region`: pass the same values
every time for a given application.

### `plan` fails with "no matching Route53Zone found"

`main_domain` must name a hosted zone that already exists in the same AWS
account the credentials resolve to. This template does not create the zone; it
looks it up by name to issue the ACM certificate for
`<app_name>.<environment>.<main_domain>` and to write the validation and alias
records.

Check the zone exists and the name matches exactly (no trailing dot, no
subdomain):

```bash
aws route53 list-hosted-zones-by-name --dns-name example.com
```

### Checkov fails on `prod` but passed on `dev`/`staging`

Intended. `prod` is scanned against `.checkov.yaml`; `dev` and `staging` use
`.checkov.nonprod.yaml`, which additionally skips three prod-only baselines:

| Check | Why it's skipped for non-prod |
|-------|-------------------------------|
| `CKV_AWS_260` | SG restricts all traffic — the dev ALB SG accepts `0.0.0.0/0` for public access |
| `CKV2_AWS_5` | SG attached to resource — false positive: SGs are defined in the networking module and attached in webapp |
| `CKV2_AWS_19` | EIP attached to EC2 — false positive: the EIP is attached to the NAT gateway |

Both configs skip a further set in every environment (ALB access logs, WAF,
KMS CMKs, image-tag pinning, non-root containers, ALB→container HTTP, ALB
deletion protection); each
entry carries its rationale inline in the file. The ALB→container one
(`CKV_AWS_378`) has a fuller write-up in
[Encrypting the ALB → Fargate hop](docs/ALB-BACKEND-TLS.md), which records why
TLS terminates at the ALB and what it would take to change that.
`CKV_AWS_103` and
`CKV2_AWS_74` are deliberately **not** skipped anywhere — every environment
uses `ELBSecurityPolicy-TLS13-1-3-2021-06`, enforced by a validation block on
the webapp module's `ssl_policy` variable, so both pass natively.

If you add a skip, put it in both files with a comment explaining why and a
tracking reference.

### Cost surprises on a first apply

The NAT gateway is the dominant line item, and it is billed hourly regardless
of traffic. `dev` and `staging` use a single shared NAT
(`single_nat_gateway = true`); `prod` provisions one per availability zone.
The ALB is the second fixed cost. Destroying an environment you're not
actively using is the effective control — `tofu destroy` from the environment
directory, or the platform's teardown workflow.

### Region requirements

Every environment assumes **at least two availability zones** — the subnet
CIDRs, the ALB and the ECS service placement all depend on it. Regions with a
single AZ are not supported.
