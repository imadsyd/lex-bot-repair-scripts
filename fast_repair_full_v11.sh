#!/bin/bash
# Fast Repair Script for AWS Lex V2 Bot
# Author: Imad Syed
# Version: 11 (final revision)

set -euo pipefail

# ====== CONFIG ======
BOT_ID="PFL1QIJU7I"
BOT_ALIAS_NAME="CorporateBot"
LOCALE_ID="en_US"
LAMBDA_ARN="arn:aws:lambda:us-east-1:037742916877:function:HelpLambda"

INTENTS=("GetForecast" "GetCorporateForecast" "CustomHelpIntent" "FallbackIntent")

declare -A SLOT_TYPES=(
  ["ForecastDays"]="AMAZON.Number"
  ["Company"]="AMAZON.Company"
  ["City"]="AMAZON.City"
)

divider() { echo "=============================="; }

log() { echo -e "$1"; }

retry_aws() {
  local cmd=$1
  local retries=3
  local count=0
  until eval "$cmd"; do
    ((count++))
    if [ $count -ge $retries ]; then
      log "❌ Failed after $retries attempts."
      exit 1
    fi
    log "⚠️  Retrying ($count/$retries)..."
    sleep 5
  done
}

log "🚀 Starting full auto-repair, rebuild, publish, and deployment for bot $BOT_ID"
divider

# ---- 1️⃣ Delete old locale ----
log "🔍 Checking existing locale..."
EXISTING_LOCALE=$(aws lexv2-models list-bot-locales \
  --bot-id "$BOT_ID" \
  --bot-version "DRAFT" \
  --query "botLocaleSummaries[?localeId=='$LOCALE_ID'].localeId" \
  --output text)

if [[ -n "$EXISTING_LOCALE" ]]; then
  log "🗑️  Deleting old locale..."
  aws lexv2-models delete-bot-locale \
    --bot-id "$BOT_ID" \
    --bot-version "DRAFT" \
    --locale-id "$LOCALE_ID" >/dev/null
  log "⌛ Waiting for full deletion..."
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

# ---- 2️⃣ Create new locale ----
log "➕ Creating new locale..."
aws lexv2-models create-bot-locale \
  --bot-id "$BOT_ID" \
  --bot-version "DRAFT" \
  --locale-id "$LOCALE_ID" \
  --nlu-intent-confidence-threshold 0.4 \
  --voice-settings '{"voiceId":"Ivy"}' >/dev/null

log "⌛ Waiting for locale to be ready..."
while true; do
  STATUS=$(aws lexv2-models describe-bot-locale \
    --bot-id "$BOT_ID" \
    --bot-version "DRAFT" \
    --locale-id "$LOCALE_ID" \
    --query "botLocaleStatus" \
    --output text 2>/dev/null)
  echo "   Current status: $STATUS"
  [[ "$STATUS" == "NotBuilt" ]] && break
  sleep 5
done

# ---- 3️⃣ Create intents and slots ----
for INTENT in "${INTENTS[@]}"; do
  log "➕ Creating intent: $INTENT"
  INTENT_ID=$(aws lexv2-models create-intent \
    --bot-id "$BOT_ID" \
    --bot-version "DRAFT" \
    --locale-id "$LOCALE_ID" \
    --intent-name "$INTENT" \
    --sample-utterances "[{\"utterance\":\"Example for $INTENT\"}]" \
    --intent-closing-setting '{"closingResponse":{"messageGroups":[{"message":{"plainTextMessage":{"value":"Done."}}}]}}' \
    --query "intentId" \
    --output text)

  log "⏳ Waiting for intent $INTENT to be available..."
  for i in {1..10}; do
    STATUS=$(aws lexv2-models describe-intent \
      --bot-id "$BOT_ID" \
      --bot-version "DRAFT" \
      --locale-id "$LOCALE_ID" \
      --intent-id "$INTENT_ID" \
      --query "intentId" \
      --output text 2>/dev/null || true)
    if [[ -n "$STATUS" ]]; then
      log "   ✅ Intent $INTENT is ready for slots."
      break
    fi
    log "   ...waiting ($i)"
    sleep 3
  done
  sleep 2

  # Slots only for weather intents
  if [[ "$INTENT" == "GetForecast" || "$INTENT" == "GetCorporateForecast" ]]; then
    for SLOT_NAME in "${!SLOT_TYPES[@]}"; do
      log "➕ Creating slot: $SLOT_NAME (type: ${SLOT_TYPES[$SLOT_NAME]})"
      retry_aws "aws lexv2-models create-slot \
        --bot-id \"$BOT_ID\" \
        --bot-version \"DRAFT\" \
        --locale-id \"$LOCALE_ID\" \
        --intent-id \"$INTENT_ID\" \
        --slot-name \"$SLOT_NAME\" \
        --slot-type-id \"${SLOT_TYPES[$SLOT_NAME]}\" \
        --value-elicitation-setting '{\"slotConstraint\":\"Optional\",\"promptSpecification\":{\"messageGroups\":[{\"message\":{\"plainTextMessage\":{\"value\":\"Please provide $SLOT_NAME\"}}}],\"maxRetries\":1,\"allowInterrupt\":true}}' >/dev/null"
    done
  fi
done

# ---- 4️⃣ Build locale ----
log "🚀 Building bot locale..."
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

# ---- 5️⃣ Publish version ----
NEW_VERSION=$(aws lexv2-models create-bot-version \
  --bot-id "$BOT_ID" \
  --query "botVersion" \
  --output text)
log "📦 Published new bot version: $NEW_VERSION"

# ---- 6️⃣ Attach Lambda to alias ----
ALIAS_ID=$(aws lexv2-models list-bot-aliases \
  --bot-id "$BOT_ID" \
  --query "botAliasSummaries[?botAliasName=='$BOT_ALIAS_NAME'].botAliasId" \
  --output text)

if [[ -z "$ALIAS_ID" ]]; then
  log "➕ Creating alias: $BOT_ALIAS_NAME"
  ALIAS_ID=$(aws lexv2-models create-bot-alias \
    --bot-id "$BOT_ID" \
    --bot-version "$NEW_VERSION" \
    --bot-alias-name "$BOT_ALIAS_NAME" \
    --query "botAliasId" \
    --output text)
fi

aws lexv2-models update-bot-alias \
  --bot-id "$BOT_ID" \
  --bot-alias-id "$ALIAS_ID" \
  --bot-version "$NEW_VERSION" \
  --bot-alias-lambda-code-hooks "[{\"lambdaCodeHook\":{\"lambdaARN\":\"$LAMBDA_ARN\",\"codeHookInterfaceVersion\":\"1.0\"}}]" >/dev/null

log "✅ Lambda attached and alias updated to version $NEW_VERSION"
log "🎉 Repair, intents, and deployment completed successfully!"

