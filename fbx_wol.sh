#!/usr/bin/env bash

# --- Paramètres ---
fbx_ip=$1
pass="Motdep60-"
mac=$2

# --- Fonction SHA1 ---
sha1 () {
  printf "%s" "$1" | openssl sha1 | awk '{print $2}'
}

# --- Fonction HMAC-SHA1 ---
hmac_sha1 () {
  local data="$1"
  local key="$2"
  printf "%s" "$data" | openssl sha1 -mac HMAC -macopt hexkey:"$key" | awk '{print $2}'
}

# --- Étape 1 : récupération du challenge ---
json=$(curl -s "http://$fbx_ip/api/latest/login/?_=$(date +%s)" -H "X-FBX-FREEBOX0S: 1")
logged_in=$(echo "$json" | jq -r '.result.logged_in')
if [ "$logged_in" == "true" ]; then
  echo "[Info] Already logged-in."
else
  challenge=$(echo "$json" | jq -r '.result.challenge')
  password_salt=$(echo "$json" | jq -r '.result.password_salt')

  h_pass=$(sha1 "${password_salt}${pass}")
  hash=$(hmac_sha1 "$challenge" "$h_pass")

  # POST login
  response=$(curl -i -s -X POST "http://$fbx_ip/api/latest/login/" \
      -H "X-FBX-FREEBOX0S: 1" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data "password=${hash}")

  cookie=$(echo "$response" | grep -i "^set-cookie:" | head -1 | cut -d' ' -f2 | tr -d '\r')
fi

# --- Étape 2 : Wake-On-Lan ---
curl -s -X POST "http://$fbx_ip/api/latest/lan/wol/pub/" \
     -H "Cookie: ${cookie}" \
     -H "X-Fbx-App-Id: fr.freebox.mafreebox" \
     -H "X-Fbx-Freebox0S: 1" \
     -H "Content-Type: application/json" \
     --data "{\"mac\":\"\$2\", \"password\":\"\"}"
echo "WOL sent to $mac on Freebox at $fbx_ip"