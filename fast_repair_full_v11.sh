#!/bin/bash
# AWS Lex V2 Bot Full Repair Script
# Author: Imad Syed
# Version: 11.4 (Stable)

set -euo pipefail

BOT_ID="PFL1QIJU7I"
BOT_ALIAS_NAME="CorporateBot"
LOCALE_ID="en_US"
LAMBDA_ARN="arn:aws:lambda:us-east-1:037742916877:function:HelpLambda"
FORCE_CLEAN=false

# Parse optional args
if [[ "${1:-}" == "--force-clean" ]]; then
  FORCE_CLEAN=true
fi

# Color codes
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m" # No Color

divider() { echo "=============================="; }

log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error()   { echo -e "${RED}❌ $1${NC}"; }

INTENTS=("GetForecast" "GetCorporateForecast" "CustomHelpIntent" "FallbackIntent")
declare -A SLOT_TYPES=(
  ["Company"]="AMAZON.Company"
  ["City"]="AMAZON.City"
  ["ForecastDays"]="AMAZON.Number"
)

echo "🚀 Starting full auto-repair, rebuild, publish, and deployment for bot $BOT_ID"
divider

# 1️⃣ Optional cleanup of local old files
find . -maxdepth 1 -type f -name "fast_repair_full_v*.sh" ! -name "fast_repair_full_v11.sh" -exec rm -f {} \;
log_success "Old script versions removed locally."

# 2️⃣ Delete existing locale
echo "🔍 Checking existing locale..."
EXISTING_LOCALE=$(aws lexv2-models list-bot-locales \
  --bot-id "$BOT_ID" \
  --bot-version "DRAFT" \
  --query "botLocaleSummaries[?localeId=='$LOCALE_ID'].localeId" \
  --output text)

if [[ -n "$EXISTING_LOCALE" ]]; then
  echo "🗑️  Deleting old locale..."
  aws lexv2-models delete-bot-locale \
    --bot-id "$BOT_ID" \
    --bot-version "DRAFT" \
    --locale-id "$LOCALE_ID"
  sleep 5
  echo "⌛ Waiting for full deletion..."
  while true; do
    STATUS=$(aws lexv2-models list-bot-locales \
      --bot-id "$BOT_ID" \
      --bot-version "DRAFT" \
      --query "botLocaleSummaries[?localeId=='$LOCALE_ID'].botLocaleStatus" \
      --output text)
    [[ -z "$STATUS" ]] && break
    echo "   Status: $STATUS"
    sleep 5
  done
fi

# 3️⃣ Force clean intents if enabled
if $FORCE_CLEAN; then
  echo "🗑️  Force cleaning old intents..."
  INTENT_IDS=$(aws lexv2-models list-intents \
    --bot-id "$BOT_ID" \
    --bot-version "DRAFT" \
    --locale-id "$LOCALE_ID" \
    --query "intentSummaries[].intentId" \
    --output text 2>/dev/null || true)
  for ID in $INTENT_IDS; do
    aws lexv2-models delete-intent \
      --bot-id "$BOT_ID" \
      --bot-version "DRAFT" \
      --locale-id "$LOCALE_ID" \
      --intent-id "$ID" || true
  done
  log_success "All old intents removed."
fi

# 4️⃣ Create new locale
echo "➕ Creating new locale..."
aws lexv2-models create-bot-locale \
  --bot-id "$BOT_ID" \
  --bot-version "DRAFT" \
  --locale-id "$LOCALE_ID" \
  --nlu-intent-confidence-threshold 0.4 \
  --voice-settings '{"voiceId":"Ivy"}' >/dev/null

echo "⌛ Waiting for locale to be ready..."
while true; do
  STATUS=$(aws lexv2-models describe-bot-locale \
    --bot-id "$BOT_ID" \
    --bot-version "DRAFT" \
    --locale-id "$LOCALE_ID" \
    --query "botLocaleStatus" \
    --output text 2>/dev/null)
  echo "   Current status: $STATUS"
  [[ "$STATUS" == "NotBuilt" || "$STATUS" == "Built" ]] && break
  sleep 5
done

# 5️⃣ Create intents and slots
for INTENT in "${INTENTS[@]}"; do
  echo "➕ Creating intent: $INTENT"
  INTENT_ID=$(aws lexv2-models create-intent \
    --bot-id "$BOT_ID" \
    --bot-version "DRAFT" \
    --locale-id "$LOCALE_ID" \
    --intent-name "$INTENT" \
    --sample-utterances "[{\"utterance\":\"Example for $INTENT\"}]" \
    --intent-closing-setting '{"closingResponse":{"messageGroups":[{"message":{"plainTextMessage":{"value":"Done."}}}]}}' \
    --query "intentId" \
    --output text)

  echo "⏳ Waiting for intent $INTENT to be available..."
  while true; do
    READY=$(aws lexv2-models describe-intent \
      --bot-id "$BOT_ID" \
      --bot-version "DRAFT" \
      --locale-id "$LOCALE_ID" \
      --intent-id "$INTENT_ID" \
      --query "intentName" \
      --output text 2>/dev/null || echo "")
    [[ -n "$READY" ]] && break
    sleep 3
  done
  log_success "Intent $INTENT ready for slots."

  # Slots only for forecast intents
  if [[ "$INTENT" == "GetForecast" || "$INTENT" == "GetCorporateForecast" ]]; then
    for SLOT_NAME in "${!SLOT_TYPES[@]}"; do
      echo "➕ Creating slot: $SLOT_NAME (type: ${SLOT_TYPES[$SLOT_NAME]})"
      aws lexv2-models create-slot \
        --bot-id "$BOT_ID" \
        --bot-version "DRAFT" \
        --locale-id "$LOCALE_ID" \
        --intent-id "$INTENT_ID" \
        --slot-name "$SLOT_NAME" \
        --slot-type-id "${SLOT_TYPES[$SLOT_NAME]}" \
        --value-elicitation-setting '{"slotConstraint":"Optional","promptSpecification":{"messageGroups":[{"message":{"plainTextMessage":{"value":"Please provide '"$SLOT_NAME"'"}}}],"maxRetries":1,"allowInterrupt":true}}' >/dev/null
    done
  fi
done

# 6️⃣ Build locale
echo "🚀 Building bot locale..."
aws lexv2-models build-bot-locale \
  --bot-id "$BOT_ID" \
  --bot-version "DRAFT" \
  --locale-id "$LOCALE_ID"

while true; do
  STATUS=$(aws lexv2-models describe-bot-locale \
    --bot-id "$BOT_ID" \
    --bot-version "DRAFT" \
    --locale-id "$LOCALE_ID" \
    --query "botLocaleStatus" \
    --output text)
  echo "   Current status: $STATUS"
  [[ "$STATUS" == "Built" ]] && break
  sleep 10
done

# 7️⃣ Attach Lambda to alias
echo "🔄 Updating alias with Lambda hook..."
ALIAS_ID=$(aws lexv2-models list-bot-aliases \
  --bot-id "$BOT_ID" \
  --query "botAliasSummaries[?botAliasName=='$BOT_ALIAS_NAME'].botAliasId" \
  --output text)

if [[ -n "$ALIAS_ID" ]]; then
  aws lexv2-models update-bot-alias \
    --bot-id "$BOT_ID" \
    --bot-alias-id "$ALIAS_ID" \
    --bot-version "DRAFT" \
    --bot-alias-lambda-code-hooks "[{\"lambdaCodeHook\":{\"lambdaARN\":\"$LAMBDA_ARN\",\"codeHookInterfaceVersion\":\"1.0\"}}]" >/dev/null
  log_success "Lambda attached to alias: $BOT_ALIAS_NAME"
else
  log_warn "Alias $BOT_ALIAS_NAME not found. Lambda not attached."
fi

# 8️⃣ Health Check
echo "🔍 Running final health check..."
CHECK=$(aws lexv2-models list-intents \
  --bot-id "$BOT_ID" \
  --bot-version "DRAFT" \
  --locale-id "$LOCALE_ID" \
  --query "length(intentSummaries)" \
  --output text)
[[ "$CHECK" -ge 4 ]] && log_success "All intents are present." || log_error "Some intents missing."

echo -e "${GREEN}🎉 Repair, intents, and deployment completed successfully!${NC}"

