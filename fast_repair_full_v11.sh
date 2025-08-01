#!/bin/bash
# Fast Repair Script for AWS Lex V2 Bot
# Author: Imad Syed
# Version: 11.6 - Cleanup, Orphan Alias Handling, Slot Retry Stability

set -euo pipefail

# ===== CONFIGURATION =====
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
log() { echo -e "\033[1;36m[$(date '+%H:%M:%S')]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; }

log "🚀 Starting full auto-repair, rebuild, publish, and deployment for bot $BOT_ID"
divider

# ===== 1️⃣ CLEANUP OLD LOCALE =====
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
    --locale-id "$LOCALE_ID" || true

  log "⌛ Waiting for full deletion..."
  for i in {1..30}; do
    STATUS=$(aws lexv2-models list-bot-locales \
      --bot-id "$BOT_ID" \
      --bot-version "DRAFT" \
      --query "botLocaleSummaries[?localeId=='$LOCALE_ID'].botLocaleStatus" \
      --output text)
    [[ -z "$STATUS" ]] && break
    sleep 5
  done
fi

# ===== 2️⃣ CREATE NEW LOCALE =====
log "➕ Creating new locale..."
aws lexv2-models create-bot-locale \
  --bot-id "$BOT_ID" \
  --bot-version "DRAFT" \
  --locale-id "$LOCALE_ID" \
  --nlu-intent-confidence-threshold 0.4 \
  --voice-settings '{"voiceId":"Ivy"}' >/dev/null

log "⌛ Waiting for locale to be ready..."
for i in {1..30}; do
  STATUS=$(aws lexv2-models describe-bot-locale \
    --bot-id "$BOT_ID" \
    --bot-version "DRAFT" \
    --locale-id "$LOCALE_ID" \
    --query "botLocaleStatus" \
    --output text 2>/dev/null)
  [[ "$STATUS" == "NotBuilt" ]] && break
  sleep 5
done

# ===== 3️⃣ CREATE INTENTS & SLOTS =====
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
  sleep 4

  if [[ "$INTENT" == "GetForecast" || "$INTENT" == "GetCorporateForecast" ]]; then
    for SLOT_NAME in "${!SLOT_TYPES[@]}"; do
      log "➕ Creating slot: $SLOT_NAME (type: ${SLOT_TYPES[$SLOT_NAME]})"
      for attempt in {1..3}; do
        if aws lexv2-models create-slot \
          --bot-id "$BOT_ID" \
          --bot-version "DRAFT" \
          --locale-id "$LOCALE_ID" \
          --intent-id "$INTENT_ID" \
          --slot-name "$SLOT_NAME" \
          --slot-type-id "${SLOT_TYPES[$SLOT_NAME]}" \
          --value-elicitation-setting '{"slotConstraint":"Optional","promptSpecification":{"messageGroups":[{"message":{"plainTextMessage":{"value":"Please provide '"$SLOT_NAME"'"}}}],"maxRetries":1,"allowInterrupt":true}}' >/dev/null; then
          break
        else
          warn "Retrying slot creation: $SLOT_NAME (attempt $attempt)..."
          sleep 3
        fi
      done
    done
  fi
done

# ===== 4️⃣ BUILD LOCALE =====
log "🚀 Building bot locale..."
aws lexv2-models build-bot-locale \
  --bot-id "$BOT_ID" \
  --bot-version "DRAFT" \
  --locale-id "$LOCALE_ID"

for i in {1..30}; do
  STATUS=$(aws lexv2-models describe-bot-locale \
    --bot-id "$BOT_ID" \
    --bot-version "DRAFT" \
    --locale-id "$LOCALE_ID" \
    --query "botLocaleStatus" \
    --output text)
  [[ "$STATUS" == "Built" ]] && break
  sleep 10
done

# ===== 5️⃣ PUBLISH NEW VERSION =====
NEW_VERSION=$(aws lexv2-models create-bot-version \
  --bot-id "$BOT_ID" \
  --query "botVersion" \
  --output text)

log "📢 Published bot version: $NEW_VERSION"

# ===== 6️⃣ UPDATE ALIAS =====
ALIAS_ID=$(aws lexv2-models list-bot-aliases \
  --bot-id "$BOT_ID" \
  --query "botAliasSummaries[?botAliasName=='$BOT_ALIAS_NAME'].botAliasId" \
  --output text)

if [[ -n "$ALIAS_ID" ]]; then
  log "🔄 Updating alias $BOT_ALIAS_NAME..."
  aws lexv2-models update-bot-alias \
    --bot-id "$BOT_ID" \
    --bot-alias-id "$ALIAS_ID" \
    --bot-version "$NEW_VERSION" \
    --bot-alias-lambda-code-hooks "[{\"lambdaCodeHook\":{\"lambdaARN\":\"$LAMBDA_ARN\",\"codeHookInterfaceVersion\":\"1.0\"}}]" >/dev/null
else
  log "➕ Creating alias $BOT_ALIAS_NAME..."
  aws lexv2-models create-bot-alias \
    --bot-id "$BOT_ID" \
    --bot-alias-name "$BOT_ALIAS_NAME" \
    --bot-version "$NEW_VERSION" \
    --bot-alias-lambda-code-hooks "[{\"lambdaCodeHook\":{\"lambdaARN\":\"$LAMBDA_ARN\",\"codeHookInterfaceVersion\":\"1.0\"}}]" >/dev/null
fi

divider
log "🎉 Repair, rebuild, publish, and deployment completed successfully!"

