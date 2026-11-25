#!/usr/bin/env bash
set -euo pipefail

ONIONOO_URL="https://onionoo.torproject.org/details"
GZ_FILE="onionoo_details.json.gz"
OUTPUT_MD="README.md"

# Download fresh archive if it doesn't exist locally
if [ ! -f "$GZ_FILE" ]; then
  echo "[*] $GZ_FILE not found, downloading from Onionoo..."
  curl -sL "$ONIONOO_URL" | gzip -9 > "$GZ_FILE"
fi

echo "[*] Parsing offline relays and calculating downtime..."

NOW_EPOCH=$(date -u +%s)
TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

# Extract offline relays with last_seen timestamp, nickname, fingerprint, IPv4/IPv6 addresses, and flags
gzip -dc "$GZ_FILE" | jq -r '
  .relays[] | select(.running == false) |
  [
    (.last_seen // "1970-01-01 00:00:00"),
    (.nickname // "Unnamed" | gsub("\\|"; "-")),
    (.fingerprint // "N/A"),
    ((.or_addresses // []) | map(sub("^\\["; "") | sub("]:[0-9]+$"; "") | sub(":[0-9]+$"; "")) | unique | join(", ")),
    (if (.flags | index("Exit") != null) then "Exit" else "Relay" end)
  ] | @tsv
' > offline_raw.tmp

# Calculate downtime in seconds for sorting, format human-readable duration, and sort ascending (lowest downtime first)
awk -F'\t' -v now="$NOW_EPOCH" '
{
  last_seen = $1
  nick = $2
  fp = $3
  ips = $4
  role = $5

  # Convert "YYYY-MM-DD HH:MM:SS" to epoch using GNU date
  cmd = "date -u -d \"" last_seen "\" +%s 2>/dev/null"
  cmd | getline seen_epoch
  close(cmd)

  if (seen_epoch == "" || seen_epoch <= 0) {
    diff = 999999999
    downtime_str = "Unknown"
  } else {
    diff = now - seen_epoch
    if (diff < 0) diff = 0

    days = int(diff / 86400)
    hours = int((diff % 86400) / 3600)
    mins = int((diff % 3600) / 60)

    if (days > 0) {
      downtime_str = sprintf("%dd %dh %dm", days, hours, mins)
    } else if (hours > 0) {
      downtime_str = sprintf("%dh %dm", hours, mins)
    } else {
      downtime_str = sprintf("%dm", mins)
    }
  }

  # Print sortable epoch diff first, followed by Markdown table row
  printf "%012d\t| %s | `%s` | %s | `%s` | %s | `%s` |\n", diff, downtime_str, last_seen, role, nick, ips, fp
}' offline_raw.tmp | sort -n | cut -f2- > offline_rows.tmp

TOTAL_OFFLINE=$(wc -l < offline_rows.tmp | tr -d ' ')

# Get raw archive size info
GZ_SIZE_HR=$(du -h "$GZ_FILE" | awk '{print $1}')
GZ_SIZE_BYTES=$(wc -c < "$GZ_FILE" | tr -d ' ')

# Write the README.md report
cat << EOF > "$OUTPUT_MD"
# Offline Tor Relays (Sorted by Lowest Downtime)

List of currently offline Tor nodes (\`running: false\`) parsed from the official [Tor Onionoo API](https://onionoo.torproject.org/), sorted from most recently seen (lowest downtime) to oldest.

* **Last Updated:** $TIMESTAMP
* **Total Offline Nodes:** \`$TOTAL_OFFLINE\`
* **Raw Archive Size:** $GZ_SIZE_HR (\`$GZ_SIZE_BYTES\` bytes)

## 📊 Offline Nodes Table

| Downtime | Last Seen (UTC) | Role | Nickname | IP Address(es) | Fingerprint |
| :--- | :--- | :--- | :--- | :--- | :--- |
EOF

cat offline_rows.tmp >> "$OUTPUT_MD"

# Cleanup temp files
rm -f offline_raw.tmp offline_rows.tmp

echo "[+] Success! Generated $OUTPUT_MD with $TOTAL_OFFLINE offline relays."
