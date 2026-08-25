#!/usr/bin/env bash
# verify.sh
# Canonical post-apply verification for this infrastructure template.
#
# Asserts that the deployed ECS Fargate stack matches the per-environment
# expectations encoded by this template's terraform/environments/<env>.
# The platform-eng orchestrator checks out the provisioned infrastructure repo
# and invokes this script at its canonical path (scripts/verify.sh) after
# `terraform apply`. Keeping the verification logic here — next to the
# Terraform that defines those expectations — means every infra template owns
# and governs its own assertions, so the orchestrator stays template-agnostic.
#
# Required env:
#   APP_NAME     application name, used as the resource name prefix
#   ENVIRONMENT  one of: dev, staging, prod
#   AWS_REGION   region the stack was applied to. Required by design, with no
#                fallback to AWS_DEFAULT_REGION or the ambient profile region:
#                nearly every AWS API this script calls is regional, so an
#                implicit region silently returns "no such resource" for a stack
#                that is deployed and healthy in another region. The same
#                reasoning makes terraform's own aws_region variable a required
#                input with no default.
#
# Optional env:
#   MAIN_DOMAIN            root domain in Route 53. When set, adds ACM
#                          certificate, Route 53 record and end-to-end HTTPS
#                          checks. The HTTPS reachability check additionally
#                          requires an internet-facing ALB, so it runs for dev
#                          only — staging and prod are internal by design.
#   GITHUB_STEP_SUMMARY    appended with a markdown summary when set
#   VERIFY_SUMMARY_FILE    machine-readable summary path (default /tmp/verify-summary.txt)
#
# Exit codes:
#   0  every check passed
#   1  checks ran, at least one failed
#   2  invalid invocation — a required variable is missing or ENVIRONMENT is not
#      one of dev/staging/prod. No checks ran.
#
# All three exits write the summary file and, when GITHUB_STEP_SUMMARY is set,
# the markdown summary — including exit 2. A caller can therefore always parse
# the summary file and never has to distinguish "failed" from "never started".

set -uo pipefail   # no -e: collect all failures, then exit at the end

VALID_ENVIRONMENTS="dev staging prod"

PASSES=()
FAILURES=()

pass()  { PASSES+=("$1"); echo "  ✓ $1"; }
fail()  { FAILURES+=("$1"); echo "  ✗ $1"; }

assert_eq() {
  if [[ "$2" == "$3" ]]; then pass "$1 = $2"
  else fail "$1: expected '$3', got '$2'"; fi
}

assert_ge() {
  if [[ "$2" -ge "$3" ]] 2>/dev/null; then pass "$1 = $2 (≥ $3)"
  else fail "$1: expected ≥ $3, got '$2'"; fi
}

assert_not_empty() {
  if [[ -n "$2" && "$2" != "null" && "$2" != "None" && "$2" != "missing" ]]; then pass "$1 = $2"
  else fail "$1: expected non-empty value, got '$2'"; fi
}

assert_one_of() {
  # $1 = label, $2 = actual, $3... = allowed values
  local label="$1" actual="$2"
  shift 2
  local allowed
  for allowed in "$@"; do
    if [[ "$actual" == "$allowed" ]]; then pass "$label = $actual"; return; fi
  done
  fail "$label: '$actual' is not approved (expected one of: $*)"
}

# TLS 1.3-only ALB policies. MUST stay in sync with the ssl_policy validation in
# terraform/modules/webapp/variables.tf — that block stops a weak policy being
# planned, this list catches one that is already deployed (drift, a console edit,
# or a stack applied before the baseline was enforced). Every other policy —
# including the ELBSecurityPolicy-TLS13-1-2-*, -TLS13-1-1-* and -TLS13-1-0-*
# variants, whose TLS13 prefix is misleading — permits TLS 1.2 or older.
APPROVED_SSL_POLICIES=(
  "ELBSecurityPolicy-TLS13-1-3-2021-06"
  "ELBSecurityPolicy-TLS13-1-3-FIPS-2023-04"
  "ELBSecurityPolicy-TLS13-1-3-RFC9151-FIPS-2023-07"
  "ELBSecurityPolicy-TLS13-1-3-PQ-2025-09"
  "ELBSecurityPolicy-TLS13-1-3-FIPS-PQ-2025-09"
)

# ── Summary emission ──────────────────────────────────────────────────────────
# Every exit path routes through here, so a caller can parse the same two
# artefacts (the step summary and the summary file) regardless of whether the run
# passed, failed its checks, or was invoked incorrectly. Array expansions are
# guarded by a length test because bash 3.2 — still the default on macOS — treats
# "${empty[@]}" as an unbound variable under `set -u`.
emit_summary() {
  local app="${APP_NAME:-(unset)}"
  local env="${ENVIRONMENT:-(unset)}"

  {
    echo "## Verify · \`$app\` / \`$env\`"
    echo ""
    echo "**Passed:** ${#PASSES[@]} · **Failed:** ${#FAILURES[@]}"
    echo ""
    if [[ ${#FAILURES[@]} -gt 0 ]]; then
      echo "### Failures"
      printf -- '- %s\n' "${FAILURES[@]}"
      echo ""
    fi
    echo "<details><summary>All checks</summary>"
    echo ""
    [[ ${#PASSES[@]}   -gt 0 ]] && printf -- '- ✓ %s\n' "${PASSES[@]}"
    [[ ${#FAILURES[@]} -gt 0 ]] && printf -- '- ✗ %s\n' "${FAILURES[@]}"
    echo ""
    echo "</details>"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

  {
    echo "environment=${env}"
    echo "passed=${#PASSES[@]}"
    echo "failed=${#FAILURES[@]}"
  } > "${VERIFY_SUMMARY_FILE:-/tmp/verify-summary.txt}"
}

# ── Input validation ──────────────────────────────────────────────────────────
# All four inputs are validated here, before the first AWS call. Every problem is
# collected and reported together rather than aborting on the first one, and the
# failure path is the same one check failures take — summary always written, so
# the caller never has to special-case "the script died before producing output".
require_env() {
  # $1 = variable name, $2 = what it is, for the error message
  if [[ -z "${!1:-}" ]]; then
    FAILURES+=("$1 is required — $2")
    echo "  ✗ $1 is required — $2" >&2
  fi
}

require_env APP_NAME    "application name, used as the resource name prefix"
require_env ENVIRONMENT "one of: ${VALID_ENVIRONMENTS// /, }"
require_env AWS_REGION  "region the stack was applied to; must match the region used for tofu apply"

# MAIN_DOMAIN is the one optional input: absent means the certificate, DNS and
# HTTPS reachability groups are skipped, which is a valid HTTP-only deployment.
MAIN_DOMAIN="${MAIN_DOMAIN:-}"

if [[ -n "${ENVIRONMENT:-}" && " ${VALID_ENVIRONMENTS} " != *" ${ENVIRONMENT} "* ]]; then
  FAILURES+=("ENVIRONMENT must be one of: ${VALID_ENVIRONMENTS// /, } — got '${ENVIRONMENT}'")
  echo "  ✗ ENVIRONMENT must be one of: ${VALID_ENVIRONMENTS// /, } — got '${ENVIRONMENT}'" >&2
fi

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  emit_summary
  echo >&2
  echo "INVALID INVOCATION: ${#FAILURES[@]} problem(s); no checks were run." >&2
  exit 2
fi

PREFIX="${APP_NAME}-${ENVIRONMENT}"
CLUSTER="${PREFIX}"
SERVICE="${PREFIX}"
ALB_NAME="alb-${PREFIX}"
LOG_GROUP="/ecs/${PREFIX}"

# ── Per-environment expectations ──────────────────────────────────────────────
case "$ENVIRONMENT" in
  dev)
    EXPECTED_CPU=256; EXPECTED_MEMORY=512
    EXPECTED_MIN_TASKS=1; EXPECTED_DESIRED=1
    EXPECTED_AUTOSCALING=false; EXPECTED_BLUE_GREEN=false
    EXPECTED_LOG_RETENTION=30; EXPECTED_ALB_SCHEME="internet-facing" ;;
  staging)
    EXPECTED_CPU=512; EXPECTED_MEMORY=1024
    EXPECTED_MIN_TASKS=1; EXPECTED_DESIRED=1
    EXPECTED_AUTOSCALING=true; EXPECTED_BLUE_GREEN=true
    EXPECTED_LOG_RETENTION=60; EXPECTED_ALB_SCHEME="internal" ;;
  prod)
    EXPECTED_CPU=1024; EXPECTED_MEMORY=2048
    EXPECTED_MIN_TASKS=3; EXPECTED_DESIRED=3
    EXPECTED_AUTOSCALING=true; EXPECTED_BLUE_GREEN=true
    EXPECTED_LOG_RETENTION=90; EXPECTED_ALB_SCHEME="internal" ;;
  *)
    # Unreachable — ENVIRONMENT is validated above. Kept so that adding a value
    # to VALID_ENVIRONMENTS without adding its expectations here fails loudly,
    # and through the same reporting path as every other exit.
    FAILURES+=("ENVIRONMENT '$ENVIRONMENT' is accepted but has no expectation set")
    emit_summary
    echo "INVALID INVOCATION: no expectation set for '$ENVIRONMENT'." >&2
    exit 2 ;;
esac

echo "Verifying $APP_NAME / $ENVIRONMENT"
echo "  Cluster: $CLUSTER  Service: $SERVICE  ALB: $ALB_NAME"

# ── ECS Cluster ───────────────────────────────────────────────────────────────
echo "::group::ECS Cluster"
CLUSTER_JSON=$(aws ecs describe-clusters --region "$AWS_REGION" --clusters "$CLUSTER" --include SETTINGS --query 'clusters[0]' --output json 2>/dev/null || echo '{}')
CLUSTER_STATUS=$(echo "$CLUSTER_JSON" | jq -r '.status // "missing"')
assert_eq "Cluster status" "$CLUSTER_STATUS" "ACTIVE"
# ECS soft-deletes clusters: a destroyed cluster is still returned, with status
# INACTIVE and its settings intact. Without this gate, Container Insights passes
# against a stack that no longer exists.
if [[ "$CLUSTER_STATUS" == "ACTIVE" ]]; then
  INSIGHTS=$(echo "$CLUSTER_JSON" | jq -r '(.settings // [] | map(select(.name=="containerInsights")) | .[0].value) // "disabled"' 2>/dev/null || echo "disabled")
  assert_eq "Container Insights" "$INSIGHTS" "enabled"
fi
echo "::endgroup::"

# ── ECS Service ───────────────────────────────────────────────────────────────
echo "::group::ECS Service"
SVC_JSON=$(aws ecs describe-services --region "$AWS_REGION" --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0]' --output json 2>/dev/null || echo '{}')
SVC_STATUS=$(echo "$SVC_JSON" | jq -r '.status // "missing"')
assert_eq "Service status" "$SVC_STATUS" "ACTIVE"
# Same soft-delete behaviour as the cluster: a destroyed service is returned with
# status INACTIVE but still reports launchType FARGATE, so that assertion would
# pass on a torn-down stack.
if [[ "$SVC_STATUS" == "ACTIVE" ]]; then
  RUNNING=$(echo "$SVC_JSON" | jq -r '.runningCount // 0')
  assert_ge "Running tasks" "$RUNNING" "$EXPECTED_MIN_TASKS"
  DESIRED=$(echo "$SVC_JSON" | jq -r '.desiredCount // 0')
  assert_ge "Desired tasks" "$DESIRED" "$EXPECTED_DESIRED"
  LAUNCH_TYPE=$(echo "$SVC_JSON" | jq -r '.launchType // "missing"')
  assert_eq "Launch type" "$LAUNCH_TYPE" "FARGATE"
fi
echo "::endgroup::"

# ── Task Definition ───────────────────────────────────────────────────────────
echo "::group::Task Definition"
# Gated on the service being live, not merely on a task-definition ARN being
# present. A deregistered revision stays readable indefinitely and keeps every
# attribute, so a destroyed stack would pass all five assertions below.
#
# The two role assertions check the ARNs recorded in the task definition, which
# is not evidence those roles still exist — the IAM group asserts that separately.
TASK_DEF_ARN=$(echo "$SVC_JSON" | jq -r '.taskDefinition // "missing"')
if [[ "$SVC_STATUS" == "ACTIVE" && "$TASK_DEF_ARN" != "missing" ]]; then
  TASK_JSON=$(aws ecs describe-task-definition --region "$AWS_REGION" --task-definition "$TASK_DEF_ARN" --query 'taskDefinition' --output json 2>/dev/null || echo '{}')
  TASK_CPU=$(echo "$TASK_JSON" | jq -r '.cpu // "0"')
  assert_eq "Task CPU" "$TASK_CPU" "$EXPECTED_CPU"
  TASK_MEM=$(echo "$TASK_JSON" | jq -r '.memory // "0"')
  assert_eq "Task memory" "$TASK_MEM" "$EXPECTED_MEMORY"
  NETWORK_MODE=$(echo "$TASK_JSON" | jq -r '.networkMode // "missing"')
  assert_eq "Network mode" "$NETWORK_MODE" "awsvpc"
  TASK_ROLE=$(echo "$TASK_JSON" | jq -r '.taskRoleArn // ""')
  assert_not_empty "Task role ARN" "$TASK_ROLE"
  EXEC_ROLE=$(echo "$TASK_JSON" | jq -r '.executionRoleArn // ""')
  assert_not_empty "Execution role ARN" "$EXEC_ROLE"
fi
echo "::endgroup::"

# ── Application Load Balancer ─────────────────────────────────────────────────
echo "::group::ALB"
ALB_JSON=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --names "$ALB_NAME" --query 'LoadBalancers[0]' --output json 2>/dev/null || echo '{}')
ALB_STATE=$(echo "$ALB_JSON" | jq -r '.State.Code // "missing"')
assert_eq "ALB state" "$ALB_STATE" "active"
ALB_SCHEME=$(echo "$ALB_JSON" | jq -r '.Scheme // "missing"')
assert_eq "ALB scheme" "$ALB_SCHEME" "$EXPECTED_ALB_SCHEME"
ALB_TYPE=$(echo "$ALB_JSON" | jq -r '.Type // "missing"')
assert_eq "ALB type" "$ALB_TYPE" "application"
echo "::endgroup::"

# ── ALB TLS policy ────────────────────────────────────────────────────────────
# The HTTPS listener is only created when a certificate was issued, which the
# webapp module gates on main_domain — so this is skipped for a valid HTTP-only
# deployment, matching how the certificate and DNS groups behave.
if [[ -n "$MAIN_DOMAIN" ]]; then
  echo "::group::ALB TLS Policy"
  ALB_ARN_FOR_TLS=$(echo "$ALB_JSON" | jq -r '.LoadBalancerArn // ""')
  if [[ -z "$ALB_ARN_FOR_TLS" || "$ALB_ARN_FOR_TLS" == "null" ]]; then
    fail "HTTPS listener TLS policy: ALB not found"
  else
    HTTPS_SSL_POLICY=$(aws elbv2 describe-listeners \
      --region "$AWS_REGION" \
      --load-balancer-arn "$ALB_ARN_FOR_TLS" \
      --query 'Listeners[?Port==`443`].SslPolicy | [0]' \
      --output text 2>/dev/null || echo "missing")
    assert_one_of "HTTPS listener TLS policy" "${HTTPS_SSL_POLICY:-missing}" "${APPROVED_SSL_POLICIES[@]}"
  fi
  echo "::endgroup::"
fi

# ── ALB Target Group health ────────────────────────────────────────────────────
echo "::group::ALB Target Group"
ALB_ARN=$(echo "$ALB_JSON" | jq -r '.LoadBalancerArn // ""')
if [[ -n "$ALB_ARN" && "$ALB_ARN" != "null" ]]; then
  TG_JSON=$(aws elbv2 describe-target-groups --region "$AWS_REGION" --load-balancer-arn "$ALB_ARN" --query 'TargetGroups[0]' --output json 2>/dev/null || echo '{}')
  TG_ARN=$(echo "$TG_JSON" | jq -r '.TargetGroupArn // ""')
  if [[ -n "$TG_ARN" && "$TG_ARN" != "null" ]]; then
    HEALTH_JSON=$(aws elbv2 describe-target-health --region "$AWS_REGION" --target-group-arn "$TG_ARN" --query 'TargetHealthDescriptions' --output json 2>/dev/null || echo '[]')
    HEALTHY=$(echo "$HEALTH_JSON" | jq '[.[] | select(.TargetHealth.State=="healthy")] | length')
    assert_ge "Healthy targets" "$HEALTHY" "$EXPECTED_MIN_TASKS"
  else
    fail "ALB target group ARN: not found"
  fi
fi
echo "::endgroup::"

# ── Auto Scaling ──────────────────────────────────────────────────────────────
echo "::group::Auto Scaling"
if [[ "$EXPECTED_AUTOSCALING" == "true" ]]; then
  SCALING_JSON=$(aws application-autoscaling describe-scalable-targets \
    --region "$AWS_REGION" \
    --service-namespace ecs \
    --query "ScalableTargets[?ResourceId=='service/${CLUSTER}/${SERVICE}'] | [0]" \
    --output json 2>/dev/null || echo '{}')
  SCALING_RESOURCE=$(echo "$SCALING_JSON" | jq -r '.ResourceId // "missing"')
  assert_not_empty "Autoscaling target" "$SCALING_RESOURCE"
  MIN_CAP=$(echo "$SCALING_JSON" | jq -r '.MinCapacity // 0')
  assert_ge "Autoscaling min capacity" "$MIN_CAP" "$EXPECTED_MIN_TASKS"
  POLICY_COUNT=$(aws application-autoscaling describe-scaling-policies \
    --region "$AWS_REGION" \
    --service-namespace ecs \
    --query "ScalingPolicies[?ResourceId=='service/${CLUSTER}/${SERVICE}'] | length(@)" \
    --output text 2>/dev/null || echo 0)
  assert_ge "Autoscaling policies" "$POLICY_COUNT" 2
else
  pass "Auto scaling disabled (not expected for $ENVIRONMENT)"
fi
echo "::endgroup::"

# ── CloudWatch Logs ────────────────────────────────────────────────────────────
echo "::group::CloudWatch Logs"
LOG_JSON=$(aws logs describe-log-groups --region "$AWS_REGION" --log-group-name-prefix "$LOG_GROUP" --query 'logGroups[0]' --output json 2>/dev/null || echo '{}')
LOG_NAME=$(echo "$LOG_JSON" | jq -r '.logGroupName // "missing"')
assert_not_empty "Log group" "$LOG_NAME"
LOG_RETENTION=$(echo "$LOG_JSON" | jq -r '.retentionInDays // 0')
assert_eq "Log retention days" "$LOG_RETENTION" "$EXPECTED_LOG_RETENTION"
echo "::endgroup::"

# ── IAM Roles ─────────────────────────────────────────────────────────────────
echo "::group::IAM"
EXEC_ROLE_NAME="ecs-exec-${PREFIX}"
TASK_ROLE_NAME="ecs-task-${PREFIX}"
EXEC_ROLE_JSON=$(aws iam get-role --region "$AWS_REGION" --role-name "$EXEC_ROLE_NAME" --query 'Role' --output json 2>/dev/null || echo '{}')
assert_not_empty "Task execution role" "$(echo "$EXEC_ROLE_JSON" | jq -r '.RoleId // ""')"
TASK_ROLE_JSON=$(aws iam get-role --region "$AWS_REGION" --role-name "$TASK_ROLE_NAME" --query 'Role' --output json 2>/dev/null || echo '{}')
assert_not_empty "Task role" "$(echo "$TASK_ROLE_JSON" | jq -r '.RoleId // ""')"
echo "::endgroup::"

# ── CodeDeploy (staging + prod only) ─────────────────────────────────────────
if [[ "$EXPECTED_BLUE_GREEN" == "true" ]]; then
  echo "::group::CodeDeploy"
  CD_APP="cd-${PREFIX}"
  CD_APP_JSON=$(aws deploy get-application --region "$AWS_REGION" --application-name "$CD_APP" --query 'application' --output json 2>/dev/null || echo '{}')
  assert_not_empty "CodeDeploy app" "$(echo "$CD_APP_JSON" | jq -r '.applicationId // ""')"
  CD_DG_JSON=$(aws deploy get-deployment-group \
    --region "$AWS_REGION" \
    --application-name "$CD_APP" \
    --deployment-group-name "${PREFIX}-dg" \
    --query 'deploymentGroupInfo' \
    --output json 2>/dev/null || echo '{}')
  DG_STATUS=$(echo "$CD_DG_JSON" | jq -r '.deploymentGroupId // ""')
  assert_not_empty "CodeDeploy deployment group" "$DG_STATUS"
  echo "::endgroup::"
fi

# ── VPC and Networking ────────────────────────────────────────────────────────
echo "::group::Networking"
# Fetch every match rather than indexing [0]: taking the first of an unknown number
# would assert against an arbitrary VPC. Exactly one is the only correct outcome —
# zero means the stack is absent or mis-tagged, more than one means the tags no
# longer identify a single stack (a half-destroyed deployment, a duplicate) and
# picking either would make the remaining assertions meaningless.
VPCS_JSON=$(aws ec2 describe-vpcs \
  --region "$AWS_REGION" \
  --filters "Name=tag:application,Values=${APP_NAME}" \
            "Name=tag:environment,Values=${ENVIRONMENT}" \
            "Name=tag:platform,Values=platform-engineering" \
  --query 'Vpcs' --output json 2>/dev/null || echo '[]')
VPC_COUNT=$(echo "$VPCS_JSON" | jq 'length' 2>/dev/null || echo 0)

if [[ "${VPC_COUNT:-0}" -eq 1 ]] 2>/dev/null; then
  pass "VPC uniquely identified by application+environment+platform tags"
  VPC_JSON=$(echo "$VPCS_JSON" | jq -r '.[0]')
  VPC_STATE=$(echo "$VPC_JSON" | jq -r '.State // "missing"')
  assert_eq "VPC state" "$VPC_STATE" "available"
  FLOW_LOG_COUNT=$(aws ec2 describe-flow-logs \
    --region "$AWS_REGION" \
    --filter "Name=resource-id,Values=$(echo "$VPC_JSON" | jq -r '.VpcId // ""')" \
    --query 'FlowLogs | length(@)' --output text 2>/dev/null || echo 0)
  assert_ge "VPC flow logs" "${FLOW_LOG_COUNT:-0}" 1
else
  # Downstream VPC assertions are deliberately skipped: with no unambiguous VPC
  # they would either repeat this failure or test the wrong resource.
  VPC_IDS=$(echo "$VPCS_JSON" | jq -r '[.[].VpcId] | join(", ")' 2>/dev/null || echo "")
  fail "VPC lookup: expected exactly 1 VPC tagged application=${APP_NAME} environment=${ENVIRONMENT} platform=platform-engineering, found ${VPC_COUNT:-0}${VPC_IDS:+ ($VPC_IDS)}"
fi
echo "::endgroup::"

# ── ACM Certificate ───────────────────────────────────────────────────────────
if [[ -n "$MAIN_DOMAIN" ]]; then
  echo "::group::ACM Certificate"
  EXPECTED_FQDN="${APP_NAME}.${ENVIRONMENT}.${MAIN_DOMAIN}"
  CERT_ARN=$(aws acm list-certificates --region "$AWS_REGION" \
    --query "CertificateSummaryList[?DomainName=='${EXPECTED_FQDN}'].CertificateArn | [0]" \
    --output text 2>/dev/null || echo "")
  if [[ -z "$CERT_ARN" || "$CERT_ARN" == "None" ]]; then
    fail "Certificate for ${EXPECTED_FQDN}: not found"
  else
    pass "Certificate ARN = $CERT_ARN"
    CERT_JSON=$(aws acm describe-certificate --region "$AWS_REGION" \
      --certificate-arn "$CERT_ARN" --query 'Certificate' --output json 2>/dev/null || echo '{}')
    CERT_STATUS=$(echo "$CERT_JSON" | jq -r '.Status // "missing"')
    assert_eq "Certificate status" "$CERT_STATUS" "ISSUED"
    CERT_DOMAIN=$(echo "$CERT_JSON" | jq -r '.DomainName // "missing"')
    assert_eq "Certificate domain" "$CERT_DOMAIN" "$EXPECTED_FQDN"
  fi
  echo "::endgroup::"
fi

# ── Route 53 DNS Records ──────────────────────────────────────────────────────
if [[ -n "$MAIN_DOMAIN" ]]; then
  echo "::group::Route 53 DNS"
  EXPECTED_FQDN="${APP_NAME}.${ENVIRONMENT}.${MAIN_DOMAIN}"
  ZONE_ID=$(aws route53 list-hosted-zones \
    --query "HostedZones[?Name=='${MAIN_DOMAIN}.'].Id | [0]" \
    --output text 2>/dev/null | sed 's|/hostedzone/||')
  if [[ -z "$ZONE_ID" || "$ZONE_ID" == "None" ]]; then
    fail "Public hosted zone for ${MAIN_DOMAIN}: not found"
  else
    pass "Public hosted zone = $ZONE_ID"
    DNS_JSON=$(aws route53 list-resource-record-sets \
      --hosted-zone-id "$ZONE_ID" \
      --query "ResourceRecordSets[?Name=='${EXPECTED_FQDN}.'] | [0]" \
      --output json 2>/dev/null || echo '{}')
    DNS_TYPE=$(echo "$DNS_JSON" | jq -r '.Type // "missing"')
    assert_eq "DNS record type" "$DNS_TYPE" "A"
    ALIAS_TARGET=$(echo "$DNS_JSON" | jq -r '.AliasTarget.DNSName // "missing"')
    assert_not_empty "DNS alias target" "$ALIAS_TARGET"
    VALIDATE_CNAME_COUNT=$(aws route53 list-resource-record-sets \
      --hosted-zone-id "$ZONE_ID" \
      --query "ResourceRecordSets[?Type=='CNAME' && contains(Name, '${EXPECTED_FQDN}')] | length(@)" \
      --output text 2>/dev/null || echo 0)
    assert_ge "ACM validation CNAME" "${VALIDATE_CNAME_COUNT:-0}" 1
  fi
  echo "::endgroup::"
fi

# ── Public DNS reachability (internet-facing environments only) ───────────────
# Staging and prod use an internal ALB — no public DNS check.
if [[ "$EXPECTED_ALB_SCHEME" == "internet-facing" && -n "$MAIN_DOMAIN" ]]; then
  echo "::group::Public DNS"
  PUBLIC_FQDN="${APP_NAME}.${ENVIRONMENT}.${MAIN_DOMAIN}"
  HTTP_CODE=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" "https://${PUBLIC_FQDN}/" 2>/dev/null)
  assert_eq "HTTPS ${PUBLIC_FQDN}" "${HTTP_CODE:-000}" "200"
  echo "::endgroup::"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
emit_summary

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo
  echo "FAILED: ${#FAILURES[@]} of $((${#PASSES[@]} + ${#FAILURES[@]})) checks"
  exit 1
fi

echo
echo "OK: all ${#PASSES[@]} checks passed."
