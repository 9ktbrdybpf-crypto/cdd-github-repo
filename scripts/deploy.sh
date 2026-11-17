#!/bin/env bash
set -Eeuo pipefail

MODE="${1:-}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:?AWS_ACCOUNT_ID is required}"
DEPLOY_ENV="${DEPLOY_ENV:?DEPLOY_ENV is required}"
PARAM_ENV="${PARAM_ENV:?PARAM_ENV is required}"

TEMPLATE_DIRECTORY="src"
PARAMETER_DIRECTORY="parameters"

INFRA_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/cdd-${DEPLOY_ENV}-iam-role-cfn-codepl"
IAM_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/cdd-${DEPLOY_ENV}-iam-role-cfn-iam"

CHANGE_SET_SUFFIX="${CHANGE_SET_SUFFIX:-manual-(date +%Y%m%d%H%M%S)}"
MANIFEST_FILE="${MANIFEST_FILE:-change-sets.tsv}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

log() { printf '%s\n' "$*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

chdeck_requirements() {
  command -v aws >/dev/null 2>&1 || fail "aws cli is not installed"
  command -v jq >/dev/null 2>&1 || fail "jq is not installed"
  aws sts get-caller-identity >/dev/null
}

get_templates() {
  find "${TEMPLATE_DIRECTORY}" \
    -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) \
    -print0 | sort -z
}

get_stack_name(){
  local filename
  filename="$(basename "$1")"
  filename="${filename%.yaml}"
  filename="${filename%.yml}"
  printf 'cdd-%s-cfn-stack-%s' "${DEPLOY_ENV}" "${filename}"
}

validate_stack_name() {
  [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9-]{0,127}$ ]] ||
    fail "Invalid stack name generated from template: $1"
}

is_iam_template() {
  case "$(basename "$1")" in
    iam-* | iam.yaml | iam.yml) return 0 ;;
    *) return 1 ;;
  esac
}

get_role_arn() {
  if is_iam_template "$1"; then
    printf '%s' "${IAM_ROLE_ARN}"
  else
    printf '%s' "${INFRA_ROLE_ARN}"
  fi
}

get_capabilities() {
  if is_iam_template "$1"; then
    printf 'CAPABILITY_NAMED_IAM'
  else
    printf '%s' ""
  fi
}

get_parametersfile() {
  local filename
  filename="$(basename "$1")"
  filename="${filename%.yaml}"
  filename="${filename%.yml}"
  local.path="${PARAMETER_DIRECTORY}/${PARAM_ENV}/${filename}.json"
  if [[ -f "${path}" ]]; then
    printf '%s' "${path}"
  fi
  return 0
}

get_stack_status() {
  aws cloudformation describe-stacks \
    --stack-name "$1" --region "${AWS_REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true
}

wait_for_change_set() {
  local stack_name="$1" "change_set_name="$2" status reason
  for _ in {seq 1 60}; do
    status="$(aws cloudformation describe-change-set \
      --stack-name "${stack_name}" --change-set-name "${change_set_name}" \
      --region "${AWS_REGION}" --query 'Status' --output text)"
    case "${status}" in
      CREATE_COMPLETE) return 0 ;;
      FAILED)
        reason="$(aws cloudformation describe-change-set \
          --stack-name "${stack_name}" --change-set-name "${change_set_name}" \
          --region "${AWS_REGION}" --query 'StatusReason' --output text)"
        if [[ "${reason}" == *"didn't contain changes"* ]] ||
           [[ "${reason}" == *"No updates are to be performed"* ]]; then
          return 2
        fi
        printf 'Change set creation failed: %s\n' "${reason}" >&2
        return 1
        ;;
    esac
    sleep 5
  done
  printf 'Timed out waiting for Change Set: %s\n' "${change_set_name}" >&2
  return 1
}

append_change_set_summary() {
  local stack_name="$1" change_set_name="$2" changes_json="$3" destructive_count
  destructive_count="$(jq '
  [ .[] | select(
    .ResourceChange.Action == "Remove" or
    .ResourceChange.Replacement == "True" or
    .ResourceChange.Replacement == "conditional"
  ) ] | length' <<<"${changes_json}")"
 {
  echo "## CloudFormation Change Set "
  echo ""
  echo "- **Stack**: `${stack_name}`"
  echo "- **change set**: `${change_set_name}`"
  echo ""
  if [[ "${destructive_count}" -gt 0 ]]; then
    echo "> [!WARNING]"
    echo "> Remove、置換、または条件付き置換を含みます。"
    echo "> 実行前に対象リソースを確認してください。 "
    echo ""
  fi
  echo "| Acion | Logical resource | Resource type | Replacement | "
  echo "|---|---|---|---|"