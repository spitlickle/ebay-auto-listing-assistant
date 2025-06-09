#!/bin/bash
set -e

# --- VERBOSE & IMAGEQUERY FLAG HANDLING ---
VERBOSE=0
IMAGEQUERY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose) VERBOSE=1;;
        -i|--imagequery) IMAGEQUERY=1;;
        *) ;;
    esac
    shift
done

v_echo() { [[ $VERBOSE -eq 1 ]] && echo "$@"; }

# --- LOAD CONFIG ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    source "${SCRIPT_DIR}/.env"
else
    echo "Please create a .env file in script directory."
    exit 1
fi

# Allow .env or commandline to activate multimodal/imagequery
if [[ "${MULTIMODAL_ALWAYS}" == "1" ]]; then IMAGEQUERY=1; fi

# --- CHECK DEPENDENCIES ---
need_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || { echo "Missing: $cmd. Installing..."; sudo apt-get install -y "$cmd" || exit 1; }
}
need_cmd "jq"
need_cmd "magick"
need_cmd "curl"
need_cmd "file"

# --- UTILS ---
sanitize_csv_field() {
  local s="$1"
  # Replace newlines with \n and escape quotes for CSV
  s=${s//$'\n'/\\n}
  echo "\"${s//\"/\"\"}\""
}
clean_product_name() {
  echo "$1" | sed -E 's/ ?(\(|\[)?[Uu]sed|[Mm]int|[Gg]ood|[Ff]air|[Ee]xcellent|[Nn]ew(\)|\])?//g' | sed 's/_/ /g' | xargs
}

# --- BULK CSV HEADER ---
if [[ $IMAGEQUERY -eq 1 ]]; then
    MASTER_CSV_HEADER="Folder,Product Name,Manufacturer,UPC,Weight,Year,Country,Dimensions,Other Fields,AmazonASIN,NewLink,CurrentRetail,EstValue,Description,DescriptionImage"
else
    MASTER_CSV_HEADER="Folder,Product Name,Manufacturer,UPC,Weight,Year,Country,Dimensions,Other Fields,AmazonASIN,NewLink,CurrentRetail,EstValue,Description"
fi

v_echo "Initializing bulk CSV at ${PARENT_DIR}/ebay_bulk_upload.csv"
> "${PARENT_DIR}/ebay_bulk_upload.csv"
echo "$MASTER_CSV_HEADER" > "${PARENT_DIR}/ebay_bulk_upload.csv"

find "$PARENT_DIR" -mindepth 1 -maxdepth 1 -type d | while read -r folder; do
  BASE=$(basename "$folder")
  PROD_NAME="$(clean_product_name "$BASE")"
  UPLOAD_DIR="$folder/upload"
  mkdir -p "$UPLOAD_DIR"
  v_echo "Processing: $BASE"
  v_echo "  -> Creating upload directory: $UPLOAD_DIR"

  # ---- IMAGE PROCESSING ----
  shopt -s nullglob nocaseglob
  for img in "$folder"/*.jpg "$folder"/*.jpeg; do
    filename=$(basename "$img")
    v_echo "  -> Compressing/stripping image: $filename"
    magick "$img" -strip -quality "${IMG_QUALITY}" "$UPLOAD_DIR/$filename"
  done
  shopt -u nullglob nocaseglob
  v_echo "  Image compression complete for: $BASE"

  # ---- PRODUCT INFO: GPT-4o w/ 'search' ----
  INFO_CSV="$folder/${PROD_NAME// /_}-info.csv"
  QUERY="You are a product data expert. Find factual info about the product \"$PROD_NAME\" (ignore any condition). Return a CSV table only, with columns: Product Name, Manufacturer, UPC, Shipped Weight, Date of Manufacture, Country of Manufacture, Dimensions, Amazon ASIN (if found), Link to new for sale, Current Retail Value. If unavailable, leave blank. Estimate value for USED/condition $BASE as 'Estimated Value'. ONLY output CSV table, no commentary."
  v_echo "  -> Querying OpenAI for product CSV for: $PROD_NAME"

  JSON_PAYLOAD=$(jq -cn \
    --arg model "$AI_SEARCH_MODEL" \
    --arg content "$QUERY" \
    '[{"role":"system","content":"You are an expert data-gathering assistant."},{"role":"user","content":$content}]' \
    | jq --arg model "$AI_SEARCH_MODEL" '{model:$model, messages: ., temperature:0.1, max_tokens:500}' )

  RESPONSE=$(curl -sS "$AI_SEARCH_ENDPOINT" \
   -H "Authorization: Bearer $OPENAI_API_KEY" \
   -H "Content-Type: application/json" \
   -d "$JSON_PAYLOAD"
  )

  INFO_CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty')
  if [[ -z "$INFO_CONTENT" ]]; then
      echo "[ERROR] OpenAI did not return product info for $BASE. Raw response:" >&2
      echo "$RESPONSE" >&2
      INFO_CSV_CONTENT="OpenAI API error: See log."
  else
      INFO_CSV_CONTENT=$(echo "$INFO_CONTENT" | sed -n '/```/,$p' | sed '1d;/```/q')
      [[ -z "$INFO_CSV_CONTENT" ]] && INFO_CSV_CONTENT="$INFO_CONTENT"
  fi
  echo "$INFO_CSV_CONTENT" > "$INFO_CSV"
  v_echo "    Saved info CSV: $(basename "$INFO_CSV")"

  # ---- DESCRIPTION: GPT-4.1 ----
  DESC_TXT="$folder/${PROD_NAME// /_}-desc.txt"
  DESC_QUERY="Write a brief, factual, to-the-point eBay product description for \"$BASE\" using only product data, with no extra commentary or superlatives, in a single plain text code block. Do NOT include price or unique identifiers. Example: \`\`\`This is a [manufacturer] [product name], in [condition]. Features: [key specs].\`\`\`"
  v_echo "  -> Querying OpenAI for description for: $BASE"

  DESC_JSON_PAYLOAD=$(jq -cn \
    --arg content "$DESC_QUERY" \
    '[{"role":"system","content":"You are a helpful eBay selling assistant."},{"role":"user","content":$content}]' \
    | jq --arg model "$AI_DESC_MODEL" '{model:$model, messages: ., temperature:0.3}' )

  DESC_RESPONSE=$(curl -sS "$AI_DESC_ENDPOINT" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$DESC_JSON_PAYLOAD"
  )

  DESC_CONTENT=$(echo "$DESC_RESPONSE" | jq -r '.choices[0].message.content // empty')
  if [[ -z "$DESC_CONTENT" ]]; then
      echo "[ERROR] OpenAI did not return a valid description for $BASE. Raw response:" >&2
      echo "$DESC_RESPONSE" >&2
      DESC_TXT_BLOCK="OpenAI API error: See log."
  else
      DESC_TXT_BLOCK=$(echo "$DESC_CONTENT" | sed -n '/```/,$p' | sed '1d;/```/q')
      [[ -z "$DESC_TXT_BLOCK" ]] && DESC_TXT_BLOCK="$DESC_CONTENT"
  fi
  echo "$DESC_TXT_BLOCK" > "$DESC_TXT"
  v_echo "    Saved description: $(basename "$DESC_TXT")"

  # ---- MULTIMODAL (IMAGEQUERY) CALL ----
  DESC_IMAGE_TXT=""
  DESC_IMAGE_TXT_BLOCK=""
  DESC_IMAGE_TXT_FILENAME="$folder/${PROD_NAME// /_}-desc-image.txt"

  if [[ $IMAGEQUERY -eq 1 ]]; then
      v_echo "  -> Preparing multimodal call (images + info) for: $BASE"
      # Build JSON array of image_url objects
      IMAGE_ENTRIES=()
      shopt -s nullglob nocaseglob
      for img in "$folder"/*.jpg "$folder"/*.jpeg; do
        IMG_MIME=$(file --mime-type -b "$img")
        [[ "$IMG_MIME" != image/* ]] && continue
        IMG_B64=$(base64 -w 0 "$img")
        IMAGE_ENTRIES+=("{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:${IMG_MIME};base64,${IMG_B64}\"}}")
      done
      shopt -u nullglob nocaseglob

      IMAGE_JSON=$(IFS=,; echo "${IMAGE_ENTRIES[*]}")

      INFO_BLOCK=$(cat "$INFO_CSV")
      ORIG_DESC_BLOCK=$(cat "$DESC_TXT")

      IMAGEQUERY_PROMPT="Review and if needed, supplement this eBay listing product description using only information visible in the provided images. Base your description on: (A) Product name \"$PROD_NAME\". (B) Information: $INFO_BLOCK (C) Current written description: $ORIG_DESC_BLOCK. Ensure the final eBay description includes all visually evident condition issues and unique details. Output only the final eBay description, in a single plain text code block."

      PROMPT_JSON=$(jq -Rs <<<"$IMAGEQUERY_PROMPT")

MESSAGES_JSON=$(
cat <<EOF
[
  { "role": "system", "content": "You are a helpful assistant for eBay product listing." },
  { "role": "user", "content": [
      { "type": "text", "text": $PROMPT_JSON }$([[ -n "$IMAGE_JSON" ]] && echo ", $IMAGE_JSON")
    ]
  }
]
EOF
)

      TMP_PAYLOAD=$(mktemp)
      cat > "$TMP_PAYLOAD" <<EOF
{
  "model": "$AI_IMAGEQUERY_MODEL",
  "messages": $MESSAGES_JSON,
  "temperature": 0.3
}
EOF

      v_echo "    -> Posting multimodal (vision) request with $(echo "$IMAGE_JSON" | grep -o '"type":"image_url"' | wc -l) images..."

      IMAGEQUERY_RESPONSE=$(curl -sS "$AI_IMAGEQUERY_ENDPOINT" \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d @"$TMP_PAYLOAD"
      )

      DESC_IMAGE_TXT=$(echo "$IMAGEQUERY_RESPONSE" | jq -r '.choices[0].message.content // empty')
      if [[ -z "$DESC_IMAGE_TXT" ]]; then
          echo "[ERROR] OpenAI did not return a valid image description for $BASE. Raw response:" >&2
          echo "$IMAGEQUERY_RESPONSE" >&2
          DESC_IMAGE_TXT_BLOCK="OpenAI API error: See log."
      else
          DESC_IMAGE_TXT_BLOCK=$(echo "$DESC_IMAGE_TXT" | sed -n '/```/,$p' | sed '1d;/```/q')
          [[ -z "$DESC_IMAGE_TXT_BLOCK" ]] && DESC_IMAGE_TXT_BLOCK="$DESC_IMAGE_TXT"
      fi
      echo "$DESC_IMAGE_TXT_BLOCK" > "$DESC_IMAGE_TXT_FILENAME"
      v_echo "    Saved image-based description: $(basename "$DESC_IMAGE_TXT_FILENAME")"
      rm "$TMP_PAYLOAD"
  fi

  # ---- AGGREGATE FOR BULK UPLOAD ----
  INFO_FIELDS=$(tail -n +2 "$INFO_CSV" | grep -v '^[[:space:]]*$' | head -1)
  DESC_TXT_CONTENTS=$(<"$DESC_TXT")
  DESC_IMAGE_TXT_CONTENTS=""
  if [[ $IMAGEQUERY -eq 1 ]]; then
      DESC_IMAGE_TXT_CONTENTS=$(<"$DESC_IMAGE_TXT_FILENAME")
      BULK_ROW=$(sanitize_csv_field "$BASE"),$(echo "$INFO_FIELDS" | awk -F, '{for(i=1;i<=NF;i++) printf "\"%s\",", $i}' | sed 's/,$//'),$(sanitize_csv_field "$DESC_TXT_CONTENTS"),$(sanitize_csv_field "$DESC_IMAGE_TXT_CONTENTS")
  else
      BULK_ROW=$(sanitize_csv_field "$BASE"),$(echo "$INFO_FIELDS" | awk -F, '{for(i=1;i<=NF;i++) printf "\"%s\",", $i}' | sed 's/,$//'),$(sanitize_csv_field "$DESC_TXT_CONTENTS")
  fi
  echo "$BULK_ROW" >> "${PARENT_DIR}/ebay_bulk_upload.csv"
  v_echo "    Appended master CSV row for: $BASE"
done

echo "DONE! See ${PARENT_DIR}/ebay_bulk_upload.csv for bulk import."
