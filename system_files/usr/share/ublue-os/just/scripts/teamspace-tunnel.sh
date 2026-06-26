#!/usr/bin/env bash

set -euo pipefail

AWS_CONFIG="$HOME/.aws/config"
SSH_CONFIG="$HOME/.ssh/config"
MARKER_BEGIN="# BEGIN TEAMSPACE MANAGED"
MARKER_END="# END TEAMSPACE MANAGED"

die() { echo "❌ $*" >&2; exit 1; }

# ── managed config helpers ───────────────────────────────────────────────────

managed_extract() {
  local file="$1"
  awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '$0==b{f=1;next} $0==e{f=0} f' "$file"
}

list_profiles() {
  managed_extract "$AWS_CONFIG" | grep -oP '(?<=^\[profile )\S+(?=\])' || true
}

# Print "instance_id\tname" for each instance of a given profile (from SSH config)
list_instances_for_profile() {
  local profile="$1"
  managed_extract "$SSH_CONFIG" | awk -v prof="$profile" '
    /^#/     { comment = substr($0, 3) }
    /^Host / { host = $2; name = comment; comment = "" }
    /ProxyCommand.*--profile / {
      p = $0; gsub(/.*--profile /, "", p); gsub(/ .*/, "", p)
      if (p == prof) print host "\t" name
    }
  '
}

# ── interactive mode ─────────────────────────────────────────────────────────

interactive_mode() {
  local -a _PROFILES
  mapfile -t _PROFILES < <(list_profiles)
  [[ ${#_PROFILES[@]} -gt 0 ]] || die "No Teamspace profiles found in ${AWS_CONFIG}. Run manage_teamspace_config.sh first."

  echo "❯ Select a Teamspace profile:"
  for i in "${!_PROFILES[@]}"; do
    printf "  %d) %s\n" "$((i+1))" "${_PROFILES[$i]}"
  done
  read -rp "❯ Enter number: " _sel
  [[ "$_sel" =~ ^[0-9]+$ ]] || die "Invalid selection."
  local _idx=$((_sel - 1))
  [[ "$_idx" -ge 0 && "$_idx" -lt ${#_PROFILES[@]} ]] || die "Selection out of range."
  AWS_PROFILE_NAME="${_PROFILES[$_idx]}"

  local -a _INSTANCES
  mapfile -t _INSTANCES < <(list_instances_for_profile "$AWS_PROFILE_NAME")
  [[ ${#_INSTANCES[@]} -gt 0 ]] || die "No instances configured for '${AWS_PROFILE_NAME}'. Run manage_teamspace_config.sh sync first."

  if [[ ${#_INSTANCES[@]} -eq 1 ]]; then
    INSTANCE_REF=$(cut -f1 <<< "${_INSTANCES[0]}")
    local _iname
    _iname=$(cut -f2 <<< "${_INSTANCES[0]}")
    if [[ -n "$_iname" ]]; then
      echo "Instance: $INSTANCE_REF  ($_iname)"
    else
      echo "Instance: $INSTANCE_REF"
    fi
  else
    echo "❯ Select an instance:"
    for i in "${!_INSTANCES[@]}"; do
      local _iid _iname
      _iid=$(cut -f1 <<< "${_INSTANCES[$i]}")
      _iname=$(cut -f2 <<< "${_INSTANCES[$i]}")
      if [[ -n "$_iname" ]]; then
        printf "  %d) %s  (%s)\n" "$((i+1))" "$_iid" "$_iname"
      else
        printf "  %d) %s\n" "$((i+1))" "$_iid"
      fi
    done
    read -rp "❯ Enter number: " _sel
    [[ "$_sel" =~ ^[0-9]+$ ]] || die "Invalid selection."
    _idx=$((_sel - 1))
    [[ "$_idx" -ge 0 && "$_idx" -lt ${#_INSTANCES[@]} ]] || die "Selection out of range."
    INSTANCE_REF=$(cut -f1 <<< "${_INSTANCES[$_idx]}")
  fi

  read -rp "❯ Local port: " LOCAL_PORT
  [[ -n "$LOCAL_PORT" ]] || die "Local port cannot be empty."
  read -rp "❯ Target host: " TARGET_HOST
  [[ -n "$TARGET_HOST" ]] || die "Target host cannot be empty."
  read -rp "❯ Target port: " TARGET_PORT
  [[ -n "$TARGET_PORT" ]] || die "Target port cannot be empty."
}

# ── argument handling ─────────────────────────────────────────────────────────

INSTANCE_REF=""
LOCAL_PORT=""
TARGET_HOST=""
TARGET_PORT=""
AWS_REGION="${AWS_REGION:-}"
AWS_PROFILE_NAME="${AWS_PROFILE:-}"

if [[ $# -eq 0 ]]; then
  interactive_mode
else
  if [[ $# -lt 4 ]]; then
    echo "Usage: $0 <instance-name-or-id> <local-port> <target-host> <target-port> [profile]"
    echo "Examples:"
    echo "  $0 my-ec2-name 15444 pgdb.example.com 5444 AUTOPTLATeamspace"
    echo "  $0 i-0123456789abcdef0 15444 pgdb.example.com 5444 AUTOPTLATeamspace"
    exit 1
  fi
  INSTANCE_REF="$1"
  LOCAL_PORT="$2"
  TARGET_HOST="$3"
  TARGET_PORT="$4"
  [[ $# -ge 5 ]] && AWS_PROFILE_NAME="$5"
fi

[[ -n "$AWS_PROFILE_NAME" ]] || AWS_PROFILE_NAME="default"
AWS_CMD=(aws --profile "$AWS_PROFILE_NAME")

ensure_sso_session() {
  set +e
  STS_OUTPUT="$(${AWS_CMD[@]} sts get-caller-identity --output json 2>&1)"
  STS_EXIT=$?
  set -e

  if [[ $STS_EXIT -eq 0 ]]; then
    return 0
  fi

  SSO_START_URL="$(${AWS_CMD[@]} configure get sso_start_url 2>/dev/null || true)"
  SSO_SESSION_NAME="$(${AWS_CMD[@]} configure get sso_session 2>/dev/null || true)"

  if [[ -n "$SSO_START_URL" || -n "$SSO_SESSION_NAME" ]]; then
    echo "🔐 No active AWS SSO session for profile '$AWS_PROFILE_NAME'."
    echo "➡ Running: aws sso login --profile $AWS_PROFILE_NAME"
    aws sso login --profile "$AWS_PROFILE_NAME"

    set +e
    STS_OUTPUT="$(${AWS_CMD[@]} sts get-caller-identity --output json 2>&1)"
    STS_EXIT=$?
    set -e

    if [[ $STS_EXIT -ne 0 ]]; then
      echo "$STS_OUTPUT"
      echo "❌ AWS SSO login did not produce a usable session for profile '$AWS_PROFILE_NAME'."
      exit $STS_EXIT
    fi
  fi
}

ensure_sso_session

if [[ -z "$AWS_REGION" ]]; then
  AWS_REGION="$(${AWS_CMD[@]} configure get region)"
fi

if [[ -z "$AWS_REGION" ]]; then
  echo "❌ No AWS region configured for profile '$AWS_PROFILE_NAME'."
  echo "   Configure one with:"
  echo "   aws configure set region <region> --profile $AWS_PROFILE_NAME"
  exit 1
fi

echo "👤 Using AWS profile: $AWS_PROFILE_NAME"
echo "🔍 Resolving instance: $INSTANCE_REF (region: $AWS_REGION)"

if [[ "$INSTANCE_REF" =~ ^i-[a-z0-9]+$ ]]; then
  DESCRIBE_ARGS=(--instance-ids "$INSTANCE_REF")
else
  DESCRIBE_ARGS=(--filters "Name=tag:Name,Values=$INSTANCE_REF" "Name=instance-state-name,Values=pending,running,stopping,stopped")
fi

set +e
DESCRIBE_OUTPUT=$(${AWS_CMD[@]} ec2 describe-instances \
  --region "$AWS_REGION" \
  "${DESCRIBE_ARGS[@]}" \
  --query "Reservations[].Instances[] | [0].[InstanceId,State.Name]" \
  --output text 2>&1)
DESCRIBE_EXIT=$?
set -e

if [[ $DESCRIBE_EXIT -ne 0 ]]; then
  echo "$DESCRIBE_OUTPUT"
  if [[ "$DESCRIBE_OUTPUT" == *"NoCredentials"* || "$DESCRIBE_OUTPUT" == *"Unable to locate credentials"* || "$DESCRIBE_OUTPUT" == *"ExpiredToken"* ]]; then
    echo "❌ AWS credentials are missing/expired for profile '$AWS_PROFILE_NAME'."
    echo "   Run: aws sso login --profile $AWS_PROFILE_NAME"
  fi
  exit $DESCRIBE_EXIT
fi

read -r INSTANCE_ID INSTANCE_STATE <<<"$DESCRIBE_OUTPUT"

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
  echo "❌ No EC2 instance found for '$INSTANCE_REF' in pending/running/stopping/stopped state."
  exit 1
fi

echo "✅ Found instance ID: $INSTANCE_ID (state: $INSTANCE_STATE)"

if [[ "$INSTANCE_STATE" == "stopped" ]]; then
  echo "⏳ Instance is stopped. Starting instance: $INSTANCE_ID"
  ${AWS_CMD[@]} ec2 start-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" >/dev/null
  echo "⏳ Waiting for instance to become running..."
  ${AWS_CMD[@]} ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
elif [[ "$INSTANCE_STATE" == "stopping" ]]; then
  echo "⏳ Instance is stopping. Waiting for it to stop first..."
  ${AWS_CMD[@]} ec2 wait instance-stopped --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
  echo "⏳ Starting instance: $INSTANCE_ID"
  ${AWS_CMD[@]} ec2 start-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" >/dev/null
  echo "⏳ Waiting for instance to become running..."
  ${AWS_CMD[@]} ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
elif [[ "$INSTANCE_STATE" == "pending" ]]; then
  echo "⏳ Instance is pending. Waiting for it to become running..."
  ${AWS_CMD[@]} ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
fi

echo "🚀 Starting port forwarding:"
echo "   localhost:$LOCAL_PORT → $TARGET_HOST:$TARGET_PORT (via $INSTANCE_ID)"
echo ""

# Start SSM port forwarding session
exec ${AWS_CMD[@]} ssm start-session \
  --region "$AWS_REGION" \
  --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$TARGET_HOST\"],\"portNumber\":[\"$TARGET_PORT\"],\"localPortNumber\":[\"$LOCAL_PORT\"]}"
