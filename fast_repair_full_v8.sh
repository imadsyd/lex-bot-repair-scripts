#!/bin/bash
# Fast Repair Script for AWS Lex V2 Bot
# Author: Imad Syed
# Version: 8.0

set -euo pipefail

BOT_ID="PFL1QIJU7I"
BOT_ALIAS_NAME="CorporateBot"
LOCALE_ID="en_US"
LAMBDA_ARN="arn:aws:lambda:us-east-1:037742916877:function:HelpLambda"

# Intents to add
INTENTS=("GetForecast" "GetCorporateForecast" "CustomHelpIntent" "FallbackIntent")

# Define slots
declare -A SLOT_TYPES=(
  ["Company"]="AMAZON.Company"
  ["City"]="AMAZON.City"
  ["ForecastDays"]="AMAZON.Number"
)

divider() {
  echo "=============================="
}

echo "🚀 Starting full auto-repair, rebuild, and deployment for bot $BOT_ID"
divider

### 1️⃣ Delete old locale
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

### 2️⃣ Create new locale
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

### 3️⃣ Create intents
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
  echo "✅ Intent created: $INTENT ($INTENT_ID)"

  # Create slots only for weather intents
  if [[ "$INTENT" == "GetForecast" || "$INTENT" == "GetCorporateForecast" ]]; then
    for SLOT_NAME in "${!SLOT_TYPES[@]}"; do
      echo "➕ Creating slot: $SLOT_NAME"
      aws lexv2-models create-slot \
        --bot-id "$BOT_ID" \
        --bot-version "DRAFT" \
        --locale-id "$LOCALE_ID" \
        --intent-id "$INTENT_ID" \
        --slot-name "$SLOT_NAME" \
        --slot-type-id "AMAZON.$(echo $SLOT_TYPES[$SLOT_NAME])" \
        --value-elicitation-setting '{"slotConstraint":"Optional","promptSpecification":{"messageGroups":[{"message":{"plainTextMessage":{"value":"Please provide '"$SLOT_NAME"'"}}}],"maxRetries":1,"allowInterrupt":true}}' >/dev/null
    done
  fi
done

### 4️⃣ Build locale
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

### 5️⃣ Attach Lambda
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
  echo "✅ Lambda attached to alias: $BOT_ALIAS_NAME"
fi

echo "🎉 Repair, intents, and deployment completed successfully!"

