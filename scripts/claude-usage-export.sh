#!/bin/bash

publish_locked() {
    candidate_file=$1
    usage_file=$2
    old_file=$(mktemp "${usage_file}.old.XXXXXX") || return 0
    output_file=
    trap 'rm -f "$old_file" "$output_file"' EXIT INT TERM
    output_file=$(mktemp "${usage_file}.tmp.XXXXXX") || return 0

    if [ -s "$usage_file" ] &&
        jq -e '.schema_version == 1 and (.rate_limits | type == "object")' \
            "$usage_file" >/dev/null 2>&1; then
        cp "$usage_file" "$old_file" || return 0
    else
        printf '%s\n' '{"schema_version":1,"updated_at":0,"rate_limits":{}}' \
            > "$old_file"
    fi

    now=$(date +%s)
    jq -n --argjson now "$now" \
      --slurpfile incoming "$candidate_file" \
      --slurpfile existing "$old_file" '
        def sanitize_window($window):
          if ($window | type) != "object" then null
          elif ($window.used_percentage | type) != "number" then null
          elif $window.used_percentage < 0 or $window.used_percentage > 100 then null
          elif (
            ($window | has("resets_at")) and
            $window.resets_at != null and
            ($window.resets_at | type) != "number"
          ) then null
          else {
            used_percentage: $window.used_percentage,
            resets_at: ($window.resets_at // null)
          }
          end;

        def merge_window($old_window; $new_window):
          (sanitize_window($old_window)) as $old |
          (sanitize_window($new_window)) as $new |
          if $new == null then $old
          elif $old == null then $new
          elif (($old.resets_at // null) != null and
                ($new.resets_at // null) != null) then
            if $new.resets_at < $old.resets_at then $old
            elif $new.resets_at > $old.resets_at then $new
            else {
              used_percentage: ([$old.used_percentage, $new.used_percentage] | max),
              resets_at: $old.resets_at
            }
            end
          else {
            used_percentage: ([$old.used_percentage, $new.used_percentage] | max),
            resets_at: ($old.resets_at // $new.resets_at // null)
          }
          end;

        ($existing[0]) as $raw_old |
        ($incoming[0]) as $new |
        {
          five_hour: sanitize_window($raw_old.rate_limits.five_hour),
          seven_day: sanitize_window($raw_old.rate_limits.seven_day)
        } |
        with_entries(select(.value != null)) as $old_rates |
        (
          if ($raw_old.updated_at | type) == "number" and
             ($raw_old.updated_at | isfinite)
          then $raw_old.updated_at
          else $now
          end
        ) as $old_updated_at |
        {
          five_hour: merge_window(
            ($old_rates.five_hour // null);
            ($new.rate_limits.five_hour // null)
          ),
          seven_day: merge_window(
            ($old_rates.seven_day // null);
            ($new.rate_limits.seven_day // null)
          )
        } |
        with_entries(select(.value != null)) as $merged |
        {
          schema_version: 1,
          updated_at: (
            if $merged == $old_rates then $old_updated_at
            else $now
            end
          ),
          rate_limits: $merged
        }
      ' > "$output_file" || return 0
    chmod 0600 "$output_file" || return 0
    mv -f "$output_file" "$usage_file"
}

if [ "${1:-}" = "--publish-locked" ]; then
    publish_locked "$2" "$3"
    exit 0
fi

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

usage_dir=${CLIMETER_USAGE_DIR:-"$HOME/Library/Application Support/Climeter"}
usage_file="$usage_dir/claude-usage.json"
lock_file="$usage_dir/claude-usage.lock"
umask 077
mkdir -p "$usage_dir" || exit 0
chmod 0700 "$usage_dir" || exit 0
: >> "$lock_file" || exit 0
chmod 0600 "$lock_file" || exit 0

candidate_file=$(mktemp "$usage_dir/.claude-usage.candidate.XXXXXX") || exit 0
trap 'rm -f "$candidate_file"' EXIT INT TERM
printf '%s' "$input" | jq -e -c '
  def valid_window($window):
    if ($window | type) != "object" then false
    else
      ($window.used_percentage | type) == "number" and
      $window.used_percentage >= 0 and
      $window.used_percentage <= 100 and
      (
        ($window | has("resets_at") | not) or
        $window.resets_at == null or
        ($window.resets_at | type) == "number"
      )
    end;

  {
    schema_version: 1,
    updated_at: (now | floor),
    rate_limits: (
      {}
      + (
        if valid_window(.rate_limits.five_hour) then {
          five_hour: {
            used_percentage: .rate_limits.five_hour.used_percentage,
            resets_at: (.rate_limits.five_hour.resets_at // null)
          }
        } else {} end
      )
      + (
        if valid_window(.rate_limits.seven_day) then {
          seven_day: {
            used_percentage: .rate_limits.seven_day.used_percentage,
            resets_at: (.rate_limits.seven_day.resets_at // null)
          }
        } else {} end
      )
    )
  }
  | select(.rate_limits | length > 0)
' > "$candidate_file" || exit 0
chmod 0600 "$candidate_file" || exit 0

script_path=$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")
/usr/bin/lockf -k -t 1 "$lock_file" \
    /bin/bash "$script_path" --publish-locked "$candidate_file" "$usage_file" \
    >/dev/null 2>&1
exit 0
