#!/usr/bin/env bash
set -euo pipefail

ONIONOO_URL="https://onionoo.torproject.org/details"
GZ_FILE="onionoo_details.json.gz"
OUTPUT_MD="README.md"
NETWORK_MD="NETWORK.md"
STATS_MD="STATS.md"
CACHE_FILE=".last_modified"
HEADERS_FILE="headers.tmp"
TEMP_RAW="onionoo_details.tmp"

# Prepare curl arguments (requesting gzip from server)
CURL_ARGS=("-sL" "-D" "$HEADERS_FILE" "-w" "%{http_code}" "-H" "Accept-Encoding: gzip" "-o" "$TEMP_RAW")

# If both the gz file and timestamp cache exist, add the If-Modified-Since header
if [ -f "$GZ_FILE" ] && [ -f "$CACHE_FILE" ]; then
  LAST_MODIFIED_VAL=$(cat "$CACHE_FILE")
  echo "[*] Checking Onionoo for updates (If-Modified-Since: $LAST_MODIFIED_VAL)..."
  CURL_ARGS+=("-H" "If-Modified-Since: $LAST_MODIFIED_VAL")
else
  echo "[*] No local cache found. Downloading fresh Onionoo details..."
fi

# Execute curl and capture the HTTP status code
HTTP_CODE=$(curl "${CURL_ARGS[@]}" "$ONIONOO_URL")

if [ "$HTTP_CODE" -eq 304 ]; then
  echo "[*] Onionoo data is not modified (304 Not Modified). Stopping execution."
  rm -f "$TEMP_RAW" "$HEADERS_FILE"
  exit 0
elif [ "$HTTP_CODE" -eq 200 ]; then
  echo "[*] New data available (200 OK). Compressing and updating cache..."
  
  # Ensure it is properly gzipped before saving as our target .gz file
  gzip -9 < "$TEMP_RAW" > "$GZ_FILE"
  
  # Extract and save the new Last-Modified header value
  grep -i "^Last-Modified:" "$HEADERS_FILE" | cut -d' ' -f2- | tr -d '\r' > "$CACHE_FILE"
  rm -f "$TEMP_RAW" "$HEADERS_FILE"
else
  echo "[!] Unexpected HTTP status code: $HTTP_CODE"
  rm -f "$TEMP_RAW" "$HEADERS_FILE"
  exit 1
fi

echo "[*] Parsing offline relays and aggregating by ASN..."

NOW_EPOCH=$(date -u +%s)
TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

# 1. Extract individual offline relays with AS number and ASN name for README.md
gzip -dc "$GZ_FILE" | jq -r '
  .relays[] | select(.running == false) |
  [
    (.last_seen // "1970-01-01 00:00:00"),
    (.nickname // "Unnamed" | gsub("\\|"; "-")),
    (.fingerprint // "N/A"),
    ((.or_addresses // []) | map(sub("^\\["; "") | sub("]:[0-9]+$"; "") | sub(":[0-9]+$"; "")) | unique | join(", ")),
    (if (.flags | index("Exit") != null) then "Exit" else "Relay" end),
    (.as // "AS0"),
    (.as_name // "Unknown ASN" | gsub("\\|"; "-"))
  ] | @tsv
' > offline_raw.tmp

awk -F'\t' -v now="$NOW_EPOCH" '
{
  last_seen = $1; nick = $2; fp = $3; ips = $4; role = $5; asn = $6; asname = $7
  cmd = "date -u -d \"" last_seen "\" +%s 2>/dev/null"
  cmd | getline seen_epoch
  close(cmd)

  if (seen_epoch == "" || seen_epoch <= 0) {
    diff = 999999999; downtime_str = "Unknown"
  } else {
    diff = now - seen_epoch
    if (diff < 0) diff = 0
    days = int(diff / 86400); hours = int((diff % 86400) / 3600); mins = int((diff % 3600) / 60)
    if (days > 0) downtime_str = sprintf("%dd %dh %dm", days, hours, mins)
    else if (hours > 0) downtime_str = sprintf("%dh %dm", hours, mins)
    else downtime_str = sprintf("%dm", mins)
  }
  
  asn_formatted = sprintf("`%s` (%s)", asn, asname)
  printf "%012d\t| %s | `%s` | %s | `%s` | %s | `%s` |\n", diff, downtime_str, last_seen, role, nick, asn_formatted, ips, fp
}' offline_raw.tmp | sort -n | cut -f2- > offline_readme_rows.tmp

TOTAL_OFFLINE=$(wc -l < offline_readme_rows.tmp | tr -d ' ')

# 2. Extract and Aggregate by ASN for NETWORK.md and STATS metrics
gzip -dc "$GZ_FILE" | jq -r '
  .relays[] | select(.running == false) |
  (if (.flags | index("Exit") != null) then "Exit" else "Non-Exit" end) as $role |
  [
    (.as // "AS0"),
    (.as_name // "Unknown ASN" | gsub("\\|"; "-")),
    ((.country // "zz") | ascii_upcase),
    $role
  ] | @tsv
' > asn_raw.tmp

awk -F'\t' '{
    asn = $1; asname = $2; cc = $3; role = $4
    key = asn "\t" asname "\t" cc
    total[key]++
    if (role == "Exit") { exits[key]++; global_exits++ }
    else { non_exits[key]++; global_non_exits++ }
    global_total++
}
END {
    for (key in total) {
        split(key, fields, "\t")
        asn = fields[1]; asname = fields[2]; cc = fields[3]
        t = total[key]
        e = exits[key] + 0
        n = non_exits[key] + 0
        printf "%06d\t| `%s` | %s | `%s` | **%d** (%d exits + %d non) |\n", t, asn, asname, cc, t, e, n
    }
}' asn_raw.tmp | sort -nr > asn_aggregated.tmp

TOTAL_ASNS=$(wc -l < asn_aggregated.tmp | tr -d ' ')
cut -f2- asn_aggregated.tmp > network_rows.tmp

# Count total exits and non-exits globally across all ASNs
GLOBAL_EXITS=$(gzip -dc "$GZ_FILE" | jq '[.relays[] | select(.running == false) | select(.flags | index("Exit") != null)] | length')
GLOBAL_NON_EXITS=$((TOTAL_OFFLINE - GLOBAL_EXITS))

GZ_SIZE_HR=$(du -h "$GZ_FILE" | awk '{print $1}')
GZ_SIZE_BYTES=$(wc -c < "$GZ_FILE" | tr -d ' ')

# 3. Write README.md
cat << EOF > "$OUTPUT_MD"
# Offline Tor Relays (Sorted by Lowest Downtime)

List of currently offline Tor nodes (\`running: false\`) parsed from the official [Tor Onionoo API](https://onionoo.torproject.org/), sorted from most recently seen (lowest downtime) to oldest.

- **Last Updated:** $TIMESTAMP
- **Total Offline Nodes:** \`$TOTAL_OFFLINE\`
- **Raw Archive Size:** $GZ_SIZE_HR (\`$GZ_SIZE_BYTES\` bytes)

## 📊 Offline Nodes Table

| Downtime | Last Seen (UTC) | Role | Nickname | ASN & Name | IP Address(es) | Fingerprint |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
EOF

cat offline_readme_rows.tmp >> "$OUTPUT_MD"

# 4. Write NETWORK.md
cat << EOF > "$NETWORK_MD"
# Offline Tor Relays by Autonomous System (ASN)

Aggregated summary of currently offline Tor nodes (\`running: false\`) grouped by their Autonomous System Network, sorted by total offline relay count.

- **Last Updated:** $TIMESTAMP
- **Total Offline Nodes:** \`$TOTAL_OFFLINE\`
- **Total Unique ASNs:** \`$TOTAL_ASNS\`

## 🌐 ASN Distribution Table

| ASN Number | ASN Name | Country | Total Offline Relays |
| :--- | :--- | :--- | :--- |
EOF

cat network_rows.tmp >> "$NETWORK_MD"

# 5. Maintain / Prepend entry to STATS.md
NEW_STAT_ROW="| $TIMESTAMP | **$TOTAL_OFFLINE** | \`$TOTAL_ASNS\` | $GLOBAL_EXITS exits + $GLOBAL_NON_EXITS non-exits |"

if [ ! -f "$STATS_MD" ]; then
  cat << EOF > "$STATS_MD"
# Historical Offline Tor Relay Statistics

Log of historical snapshot metrics recorded during every automated update cycle.

| Timestamp (UTC) | Total Offline Nodes | Unique ASNs | Breakdown (Exits / Non-Exits) |
| :--- | :--- | :--- | :--- |
$NEW_STAT_ROW
EOF
else
  # Insert the new row right below the markdown table separator line
  awk -v new_row="$NEW_STAT_ROW" '
    /\| :---/ {
      print
      print new_row
      next
    }
    {print}
  ' "$STATS_MD" > stats_tmp.md && mv stats_tmp.md "$STATS_MD"
fi

rm -f offline_raw.tmp offline_readme_rows.tmp asn_raw.tmp asn_aggregated.tmp network_rows.tmp

echo "[+] Success! Generated $OUTPUT_MD, $NETWORK_MD, and prepended latest metrics to $STATS_MD."
