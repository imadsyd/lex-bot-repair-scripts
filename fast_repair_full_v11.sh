#!/bin/bash

set -e

BOT_ID="PFL1QIJU7I"
BOT_ALIAS_ID="41UO7W8UBX"
LOCALE_ID="en_US"
REGION="us-east-1"
PROFILE="default"

log() {
  echo "[$(date '+%H:%M:%S')] $1"
}

wait_for_locale() {
  while true; do
    STATUS=$(aws lexv2-models describe-bot-locale \
      --bot-id "$BOT_ID" \
      --bot-version "DRAFT" \
      --locale-id "$LOCALE_ID" \
      --region "$REGION" \
      --profile "$PROFILE" \
      --query "botLocaleStatus" \
      --output text)
    [[ "$STATUS" == "NotBuilt" ]] && break
    log "⌛ Waiting for locale to be ready..."
    sleep 5
  done
}

wait_for_intent() {
  local INTENT_ID=$1
  while true; do
    STATUS=$(aws lexv2-models describe-intent \
      --bot-id "$BOT_ID" \
      --bot-version "DRAFT" \
      --locale-id "$LOCALE_ID" \
      --intent-id "$INTENT_ID" \
      --region "$REGION" \
      --profile "$PROFILE" \
      --query "intentStatus" \
      --output text 2>/dev/null || echo "NotReady")
    [[ "$STATUS" == "Ready" ]] && break
    log "⏳ Waiting for intent to be fully ready..."
    sleep 3
  done
}

create_slot_retry() {
  local INTENT_ID=$1
  local SLOT_NAME=$2
  local SLOT_TYPE=$3
  for attempt in {1..5}; do
    if aws lexv2-models create-slot \
      --bot-id "$BOT_ID" \
      --bot-version "DRAFT" \
      --locale-id "$LOCALE_ID" \
      --intent-id "$INTENT_ID" \
      --slot-name "$SLOT_NAME" \
      --slot-type-id "$SLOT_TYPE" \
      --value-elicitation-setting "{
          \"slotConstraint\": \"Optional\",
          \"promptSpecification\": {
              \"messageGroups\": [
                  {
                      \"message\": {
                          \"plainTextMessage\": {
                              \"value\": \"Please provide $SLOT_NAME?\"
                          }
                      }
                  }
              ],
              \"maxRetries\": 2
          }
      }" \
      --region "$REGION" \
      --profile "$PROFILE" >/dev/null; then
      log "✅ Slot created: $SLOT_NAME"
      return
    else
      log "[WARN] Retrying slot creation: $SLOT_NAME (attempt $attempt)..."
      sleep $((2 ** attempt))
    fi
  done
  log "[ERROR] Slot creation failed for $SLOT_NAME after multiple attempts."
}

log "🚀 Starting full auto-repair, rebuild, publish, and deployment for bot $BOT_ID"
log "=============================="

# Delete old locale
log "🔍 Checking existing locale..."
aws lexv2-models describe-bot-locale \
  --bot-id "$BOT_ID" \
  --bot-version "DRAFT" \
  --locale-id "$LOCALE_ID" \
  --region "$REGION" \
  --profile "$PROFILE" &>/dev/null && {
    log "🗑️  Deleting old locale..."
    aws lexv2-models delete-bot-locale \
      --bot-id "$BOT_ID" \
      --bot-version "DRAFT" \
      --locale-id "$LOCALE_ID" \
      --region "$REGION" \
      --profile "$PROFILE"
    log "⌛ Waiting for full deletion..."
    sleep 7
}

# Recreate locale
log "➕ Creating new locale..."
aws lexv2-models create-bot-locale \
  --bot-id "$BOT_ID" \
  --bot-version "DRAFT" \
  --locale-id "$LOCALE_ID" \
  --nlu-intent-confidence-threshold 0.40 \
  --voice-settings "voiceId=Ivy,engine=neural" \
  --region "$REGION" \
  --profile "$PROFILE" >/dev/null

wait_for_locale

# -------- INTENT: GetForecast --------
log "➕ Creating intent: GetForecast"
GET_FORECAST_INTENT=$(aws lexv2-models create-intent \
  --bot-id "$BOT_ID" \
  --bot-version "DRAFT" \
  --locale-id "$LOCALE_ID" \
  --intent-name "GetForecast" \
  --sample-utterances '[
      {"utterance":"What is the weather today?"},
      {"utterance":"Give me the corporate forecast for {Company}"}
  ]' \
  --region "$REGION" \
  --profile "$PROFILE" \
  --query "intentId" \
  --output text)

wait_for_intent "$GET_FORECAST_INTENT"
create_slot_retry "$GET_FORECAST_INTENT" "ForecastDays" "AMAZON.Number"
create_slot_retry "$GET_FORECAST_INTENT" "Company" "AMAZON.Company"
create_slot_retry "$GET_FORECAST_INTENT" "City" "AMAZON.City"

# -------- INTENT: GetCorporateForecast --------
log "➕ Creating intent: GetCorporateForecast"
CORP_FORECAST_INTENT=$(aws lexv2-models create-intent \
  --bot-id "$BOT_ID" \
  --bot-version "DRAFT" \
  --locale-id "$LOCALE_ID" \
  --intent-name "GetCorporateForecast" \
  --sample-utterances '[
      {"utterance":"What is the corporate forecast for {Company}?"},
      {"utterance":"Give me company outlook for {Company}"}
  ]' \
  --region "$REGION" \
  --profile "$PROFILE" \
  --query "intentId" \
  --output text)

wait_for_intent "$CORP_FORECAST_INTENT"
create_slot_retry "$CORP_FORECAST_INTENT" "ForecastDays" "AMAZON.Number"
create_slot_retry "$CORP_FORECAST_INTENT" "Company" "AMAZON.Company"
create_slot_retry "$CORP_FORECAST_INTENT" "City" "AMAZON.City"

# -------- INTENT: CustomHelpIntent --------
log "➕ Creating intent: CustomHelpIntent"
HELP_INTENT=$(aws lexv2-models create-intent \
  --bot-id "$BOT_ID" \
  --bot-version "DRAFT" \
  --locale-id "$LOCALE_ID" \
  --intent-name "CustomHelpIntent" \
  --sample-utterances '[{"utterance":"help"}]' \
  --region "$REGION" \
  --profile "$PROFILE" \
  --query "intentId" \
  --output text)
wait_for_intent "$HELP_INTENT"

# -------- INTENT: CustomFallbackIntent --------
log "➕ Creating intent: CustomFallbackIntent"
aws lexv2-models create-intent \
  --bot-id "$BOT_ID" \
  --bot-version "DRAFT" \
  --locale-id "$LOCALE_ID" \
  --intent-name "CustomFallbackIntent" \
  --sample-utterances '[{"utterance":"fallback"}]' \
  --region "$REGION" \
  --profile "$PROFILE" >/dev/null

# -------- Build Locale --------
log "⚙️ Building bot locale..."
aws lexv2-models build-bot-locale \
  --bot-id "$BOT_ID" \
  --bot-version "DRAFT" \
  --locale-id "$LOCALE_ID" \
  --region "$REGION" \
  --profile "$PROFILE"

while true; do
    STATUS=$(aws lexv2-models describe-bot-locale \
        --bot-id "$BOT_ID" \
        --bot-version "DRAFT" \
        --locale-id "$LOCALE_ID" \
        --region "$REGION" \
        --profile "$PROFILE" \
        --query "botLocaleStatus" \
        --output text)
    [[ "$STATUS" == "Built" ]] && break
    log "⌛ Waiting for bot build to finish..."
    sleep 10
done

# -------- Update alias --------
log "🔗 Updating bot alias..."
aws lexv2-models update-bot-alias \
  --bot-id "$BOT_ID" \
  --bot-alias-id "$BOT_ALIAS_ID" \
  --bot-version "DRAFT" \
  --bot-alias-name "CorporateBot" \
  --region "$REGION" \
  --profile "$PROFILE" >/dev/null

log "✅ Deployment complete for $BOT_ID"

