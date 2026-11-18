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
  echo "| Action | Logical resource | Resource type | Replacement | "
  echo "|---|---|---|---|" 
  jq -r '.[] | .ResourceChange |
    "| \(.Action // "-") | `\(.LogicalResourceId // "-")` | `\(.ResourceType // "-")` | \(Replacement // "-") |"' \
    <<< "${changes_json}"
  echo ""
 } >> "${GITHUB_STEP_SUMMARY}"
}

validate_templates() {
  local template found=false
  log "Validating CloudFormation templates..."
  while IFS= read -r template; do
    found=true
    log "Validating: ${template}"
    aws cloudformation validate-template \
     --template-body "file://${template}" --region "${AWS_REGION}" >/dev/null    
  done < <(get_templates)
  [[ "${found}" == true ]] || fail "No CloudFormation templates were found."
  log "Template validation completed."
}

create_change_set() {
  local template="$1"
  local stack_name role_arn capabilities parameters_file change_set_name change_set_type
  local stack_status result changes_json
  local -a args

  stack_name="$(get_stack_name "${template}")"
  role_arn="$(get_role_arn "${template}")"
  capabilities="$(get_capabilities "${template}")"
  parameters_file="$(get_parameters_file "${template}")"
  validate_stack_name "${stack_name}"
  change_set_name="github-${CHANGE_SET_SUFFIX}"

  stack_status="$(get_stack_status "${stack_name}")"
  case "${stack_status}" in
    "" | None | REVIEW_IN_PROGRESS ) change_set_type="CREATE" ;;
    ROLLBACK_COMPLETE) fail "${stack_name} is in ROLLBACK_COMPLETE. Delete the stack first." ;;
    *_IN_PROGRESS ) fail "${stack_name} is ${stack_status}. Retry after it finishes." ;;
    *) change_set_type="UPDATE" ;;
  esac

  log ""
  log "Creating change set"
  log " Stack : ${stack_name}"
  log " Template : ${template}"
  log " Type : ${change_set_type}"
  log " ServiceRole : ${role_arn}"
  log " Parameters : ${parameters_file:-<none>}"
  log " Change set : ${change_set_name}"

  args=(
    cloudformation create-change-set 
      --stack-name "${stack_name}" 
      --change-set-name "${change_set_name}"
      --change-set-type "${change_set_type}" 
      --template-body "file://${template}" 
      --role-arn "${role_arn}" 
      --region "${AWS_REGION}" 
      --description "GitHub Actions run ${CHANGE_SET_SUFFIX}"
    )
  if [[ -n "${capabilities}" ]]; then
    args+=(--capabilities "${capabilities}")
  fi
  if [[ -n "${parameters_file}" ]]; then
    args+=(--parameters "file://${parameters_file}")
  fi
  aws "${args[@]}" > /dev/null

  set +e
  wait_for_change_set "${stack_name}" "${change_set_name}"
  result=$?
  set -e
  
  case "${result}" in
    0)
      changes_json="$(aws cloudformation describe-change-set \
        --stack-name "${stack_name}" --change-set-name "${change_set_name}" \
        --region "${AWS_REGION}" --include-property-values \
        --query 'Changes' --output json)"
      printf '%s\t%s\t%s\n' "${stack_name}" "${change_set_name}" "${change_set_type}" \
        >> "${MANIFEST_FILE}"
      append_changes_set_summary "${stack_name}" "${change_set_name}" "${changes_json}"
      log "Change set created successfully."
      ;;
    2)
      log "No changes detected for ${stack_name}."
      aws cloudformation delete-change-set \
        --stack-name "${stack_name}" --change-set-name "${change_set_name}" \
        --region "${AWS_REGION}" > /dev/null 2>&1 || true
      {
        echo "## CloudFormation Change Set"
        echo ""
        echo "- **Stack:** \`${stack_name}\`"
        echo "- **Result:** No changes"
        echo ""
      } >> "${GITHUB_STEP_SUMMARY}"
      ;;
    *)
      fail "Unable to create change set for ${stack_name}."
      ;;
  esac
}

create_change_set() {
  local template found=false
  : > "${MANIFEST_FILE}"
  while IFS= read -r -d '' template; do
    found=true
    create_change_set_for_template "${template}"
  done < <(get_templates)
  [[ "${found}" = true ]] || fail "No CloudFormation templates were found."

  if [[ -s "${MANIFEST_FILE}" ]]; then
    echo "changes_found=true" >> "${GITHUB_OUTPUT:-/dev/null}"
    log "No deployable changes were found."
  fi
}

wait_for_stack() {
  if [[ "$2" == "CREATE" ]]; then
    aws cloudformation wait stack-create-complete --stack-name "$1" --region "${AWS_REGION}"
  else
    aws cloudformation wait stack-update-complete --stack-name "$1" --region "${AWS_REGION}"
  fi
}

execute_change_set() {
  local stack_name change_set_name change_set_type
  [[ -s "${MANIFEST_FILE}" ]] || fail "Change Set manifest is missing or empty."
  while IFS=$'\t' read -r stack_name change_set_name change_set_type; do
    log ""
    log "Executing Change Set"
    log " Stack: ${stack_name}"
    log " Change Set: ${change_set_name}"
    log " Change Set Type: ${change_set_type}"
    aws cloudformation execute-change-set \
      --stack-name "${stack_name}" --change-set-name "${change_set_name}" \
      --region "${AWS_REGION}"
    wait_for_stack "${stack_name}" "${change_set_type}"
    {
      echo "## CloudFormation deployment result"
      echo ""
      echo "- **Stack:** \`${stack_name}\`"
      echo "- **Change Set:** \`${change_set_name}\`"
      echo "- **Result:** Completed"
      echo ""
    } >> "${GITHUB_STEP_SUMMARY}"
    log "Stack operation completed: ${stack_name}"
  done < "${MANIFEST_FILE}"
}

cleanup_change_sets() {
  local stack_name change_set_name change_set_type
  [[ -s "${MANIFEST_FILE}" ]] || { log "Nothing to clean up."; return 0; }
  while IFS=$'\t' read -r stack_name change_set_name change_set_type; do
    log "Deleting Change Set: ${stack_name}/${change_set_name}"
    aws cloudformation delete-change-set \
      --stack-name "${stack_name}" --change-set-name "${change_set_name}" \
      --region "${AWS_REGION}" || log "Skip (already executed or deleted)."
  done < "${MANIFEST_FILE}"
}

main() {
  check_requirements
  case "${MODE}" in
   validate) validate_templates ;;
   create) create_change_set ;;
   execute) execute_change_set ;;
   cleanup) cleanup_change_sets ;;
   *) fail "Usage: ${0} {validate|create|execute|cleanup}" ;;
  esac
}

main "$@"
    
