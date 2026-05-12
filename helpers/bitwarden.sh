#!/bin/sh
set -eu
export NODE_NO_WARNINGS=1

unlock_vault_with_retry() {
  maximum_attempts=5
  attempt=1
  stderr_file=$(mktemp)
  while [ "$attempt" -le "$maximum_attempts" ]; do
    session=$(printf '%s' "$BW_PASSWORD" | bw unlock --passwordfile /dev/stdin --raw 2>"$stderr_file" || true)
    if [ -n "$session" ]; then
      rm -f "$stderr_file"
      printf '%s' "$session"
      return 0
    fi
    echo "bw unlock attempt $attempt/$maximum_attempts returned an empty session, retrying" >&2
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done
  echo "bw unlock failed to return a session after $maximum_attempts attempts; last bw stderr:" >&2
  cat "$stderr_file" >&2
  rm -f "$stderr_file"
  return 1
}

sync_vault_with_retry() {
  maximum_attempts=5
  attempt=1
  while [ "$attempt" -le "$maximum_attempts" ]; do
    if bw sync >/dev/null && [ "$(bw list items | jq 'length')" -gt 0 ]; then
      return 0
    fi
    echo "bw sync attempt $attempt/$maximum_attempts did not populate the vault, retrying" >&2
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done
  echo "bw sync failed to populate the vault after $maximum_attempts attempts" >&2
  return 1
}

if [ -z "${BW_SESSION:-}" ]; then
  if [ -z "${BW_PASSWORD:-}" ]; then
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
      printf 'BW_PASSWORD not set, enter Bitwarden master password: ' >/dev/tty
      BW_PASSWORD=$(
        trap 'stty echo </dev/tty 2>/dev/null' EXIT
        stty -echo </dev/tty
        IFS= read -r password </dev/tty
        printf '%s' "$password"
      )
      printf '\n' >/dev/tty
      if [ -z "$BW_PASSWORD" ]; then
        echo "password entry aborted" >&2
        exit 1
      fi
    else
      echo "BW_PASSWORD must be set (no TTY available to prompt)" >&2
      exit 1
    fi
  fi

  export BW_SESSION=$(unlock_vault_with_retry)
  unset BW_PASSWORD
  sync_vault_with_retry
fi

get_custom_field() {
  item_name="$1"
  field_name="$2"
  item_json=$(bw get item "$item_name")
  field_value=$(echo "$item_json" | jq -r --arg name "$field_name" '.fields[] | select(.name==$name) | .value')
  if [ -z "$field_value" ] || [ "$field_value" = "null" ]; then
    echo "get_custom_field: empty value for '$item_name' / '$field_name'" >&2
    return 1
  fi
  printf '%s' "$field_value"
}

get_username() {
  item_name="$1"
  username=$(bw get username "$item_name")
  if [ -z "$username" ]; then
    echo "get_username: empty username for '$item_name'" >&2
    return 1
  fi
  printf '%s' "$username"
}

get_password() {
  item_name="$1"
  password=$(bw get password "$item_name")
  if [ -z "$password" ]; then
    echo "get_password: empty password for '$item_name'" >&2
    return 1
  fi
  printf '%s' "$password"
}
