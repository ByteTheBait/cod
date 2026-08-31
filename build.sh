#!/usr/bin/env bash
set -e
source "$(dirname "$0")/.env"

exec flutter build "$@" --dart-define=GOOGLE_CLIENT_ID="$GOOGLE_CLIENT_ID" --dart-define=GOOGLE_CLIENT_SECRET="$GOOGLE_CLIENT_SECRET" --dart-define=SUPABASE_URL="$SUPABASE_URL" --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY"
