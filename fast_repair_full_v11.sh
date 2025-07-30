  echo "⏳ Waiting for intent $INTENT to be available..."
  for i in {1..12}; do
    STATUS=$(aws lexv2-models describe-intent \
      --bot-id "$BOT_ID" --bot-version "DRAFT" \
      --locale-id "$LOCALE_ID" --intent-id "$INTENT_ID" \
      --query "intentStatus" --output text 2>/dev/null || echo "PENDING")
    [[ "$STATUS" == "Ready" ]] && break
    echo "   Status: $STATUS (retry $i)"
    sleep 5
  done

  if [[ "$STATUS" != "Ready" ]]; then
    echo "❌ Intent $INTENT did not reach Ready state. Skipping slots."
    continue
  fi

  if [[ "$INTENT" == "GetForecast" || "$INTENT" == "GetCorporateForecast" ]]; then
    for SLOT_NAME in "${!SLOT_TYPES[@]}"; do
      SLOT_TYPE="AMAZON.${SLOT_TYPES[$SLOT_NAME]}"
      echo "➕ Creating slot: $SLOT_NAME (type: $SLOT_TYPE)"
      success=false
      for attempt in {1..5}; do
        set +e
        aws lexv2-models create-slot \
          --bot-id "$BOT_ID" --bot-version "DRAFT" \
          --locale-id "$LOCALE_ID" --intent-id "$INTENT_ID" \
          --slot-name "$SLOT_NAME" --slot-type-id "$SLOT_TYPE" \
          --value-elicitation-setting '{"slotConstraint":"Optional","promptSpecification":{"messageGroups":[{"message":{"plainTextMessage":{"value":"Please provide '"$SLOT_NAME"'"}}}],"maxRetries":1,"allowInterrupt":true}}' && { success=true; break; }
        echo "   ⚠️ Retry $attempt for slot $SLOT_NAME..."
        sleep $((attempt * 5))
      done
      set -e
      if [ "$success" = false ]; then
        echo "❌ Failed to create slot $SLOT_NAME after multiple attempts."
      fi
    done
  fi

