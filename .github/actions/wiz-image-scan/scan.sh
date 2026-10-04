#!/usr/bin/env bash
set -euo pipefail

mkdir -p "$REPORT_DIR"
"$WIZCLI_PATH" version > "$REPORT_DIR/wizcli-version.txt"

normalized=$(printf '%s' "$INPUT_SCAN_TYPES" | tr '[:upper:]' '[:lower:]')
normalized="${normalized// /}"
[[ -n "$normalized" ]] || { echo "scan_types cannot be empty" >&2; exit 2; }

selected_vulnerabilities=false
selected_secrets=false
selected_sensitive_data=false
selected_software_supply_chain=false
selected_malware=false
IFS=',' read -r -a requested <<< "$normalized"
for scan_type in "${requested[@]}"; do
  case "$scan_type" in
    all)
      if (( ${#requested[@]} != 1 )); then
        echo "Use scan_types=all by itself" >&2
        exit 2
      fi
      selected_vulnerabilities=true
      selected_secrets=true
      selected_sensitive_data=true
      selected_software_supply_chain=true
      selected_malware=true
      ;;
    vulnerability|vulnerabilities) selected_vulnerabilities=true ;;
    secret|secrets) selected_secrets=true ;;
    data|sensitive-data|sensitive_data) selected_sensitive_data=true ;;
    supply-chain|software-supply-chain|software_supply_chain) selected_software_supply_chain=true ;;
    malware) selected_malware=true ;;
    *) echo "Unsupported image scan type: $scan_type" >&2; exit 2 ;;
  esac
done

cmd=("$WIZCLI_PATH" scan container-image "$INPUT_IMAGE")
cmd+=(--name "github:${GITHUB_REPOSITORY}:${GITHUB_RUN_ID}")
cmd+=(--scan-context-id "${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${GITHUB_JOB}")
cmd+=(--tags "github/repository=${GITHUB_REPOSITORY}")
cmd+=(--tags "github/run-id=${GITHUB_RUN_ID}")
cmd+=(--tags "github/sha=${GITHUB_SHA}")
normalized_policy_hits=$(printf '%s' "$INPUT_POLICY_HITS" | tr '[:lower:]' '[:upper:]')
cmd+=(--by-policy-hits "$normalized_policy_hits")
cmd+=(--no-color --no-style)
cmd+=(--human-output-file "$REPORT_DIR/report.txt")
cmd+=(--json-output-file "$REPORT_DIR/report.json")
cmd+=(--sarif-output-file "$REPORT_DIR/report.sarif")

[[ -f "$INPUT_DOCKERFILE" ]] && cmd+=(--dockerfile "$INPUT_DOCKERFILE")
[[ -n "$INPUT_PROJECTS" ]] && cmd+=(--projects "$INPUT_PROJECTS")
[[ -n "$INPUT_APPLICATIONS" ]] && cmd+=(--applications "$INPUT_APPLICATIONS")
[[ "$INPUT_PUBLISH" == "false" ]] && cmd+=(--no-publish)

if [[ "$normalized" != "all" ]]; then
  disabled=()
  [[ "$selected_vulnerabilities" == "false" ]] && disabled+=(Vulnerability)
  [[ "$selected_secrets" == "false" ]] && disabled+=(Secret)
  [[ "$selected_sensitive_data" == "false" ]] && disabled+=(SensitiveData)
  [[ "$selected_software_supply_chain" == "false" ]] && disabled+=(SoftwareSupplyChain)
  [[ "$selected_malware" == "false" ]] && disabled+=(Malware)
  disabled_csv=$(IFS=,; echo "${disabled[*]}")
  cmd+=(--disabled-scanners "$disabled_csv")
fi

effective_branch="${GITHUB_BASE_REF:-${GITHUB_REF_NAME:-unknown}}"
requested_profile=$(printf '%s' "$INPUT_POLICY_PROFILE" | tr '[:upper:]' '[:lower:]')
if [[ -n "$INPUT_POLICIES" ]]; then
  effective_profile=custom
  policy_csv="$INPUT_POLICIES"
else
  if [[ "$requested_profile" == "auto" ]]; then
    case "$effective_branch" in
      main|production) effective_profile=production ;;
      *) effective_profile=staging ;;
    esac
  else
    effective_profile="$requested_profile"
  fi

  case "$effective_profile" in
    production) policy_suffix=prod ;;
    staging) policy_suffix=staging ;;
  esac

  policies=()
  [[ "$selected_vulnerabilities" == "true" ]] && policies+=("alfortes-vulnerabilities-$policy_suffix")
  [[ "$selected_secrets" == "true" ]] && policies+=("alfortes-secrets-$policy_suffix")
  [[ "$selected_sensitive_data" == "true" ]] && policies+=("alfortes-sensitive-data-$policy_suffix")
  [[ "$selected_software_supply_chain" == "true" ]] && policies+=("alfortes-software-supply-chain-$policy_suffix")
  [[ "$selected_malware" == "true" ]] && policies+=("alfortes-malware-$policy_suffix")
  policy_csv=$(IFS=,; echo "${policies[*]}")
fi
cmd+=(--policies "$policy_csv")

{
  echo "effective_branch=$effective_branch"
  echo "policy_profile=$effective_profile"
  echo "policies=$policy_csv"
} >> "$REPORT_DIR/scan-metadata.txt"

set +e
"${cmd[@]}" 2>&1 | tee "$REPORT_DIR/wizcli.log"
scan_rc=${PIPESTATUS[0]}
set -e
echo "exit_code=$scan_rc" >> "$GITHUB_OUTPUT"
{
  echo "## Wiz CLI container-image scan"
  echo
  echo "- Scan types: \`$INPUT_SCAN_TYPES\`"
  echo "- Image: \`$INPUT_IMAGE\`"
  echo "- Effective branch: \`$effective_branch\`"
  echo "- Policy profile: \`$effective_profile\`"
  echo "- Policies: \`$policy_csv\`"
  echo "- Wiz CLI exit code: \`$scan_rc\`"
  echo "- Results published to Wiz: \`$INPUT_PUBLISH\`"
} >> "$GITHUB_STEP_SUMMARY"
exit "$scan_rc"
