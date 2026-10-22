#!/usr/bin/env bash
# Multi-room variant of example.sh: 2 rooms, 4 adults, 3 children (aged 5, 7 and 3).
# Runs top to bottom: every request is a plain curl call, and the values the next request needs are read
# from the response by `jget` (a tiny helper below; needs python3 or python).
# Step 5 returns the hotels; steps 6-10 then follow the first hotel/offer it finds. Prices can change and
# rooms can disappear in step 9 (the live re-check) - that is normal, just run the script again.
# Step 10 creates a HELD (unpaid, unconfirmed) order - set V23_SKIP_BOOK=1 to stop before it.
# Multi-room differences from example.sh: ROOMS_STRING (step 4), one bToken per room (step 5), and
# both bTokens sent in steps 7 and 8.
set -e

BASE_URL="$V23_BASE_URL"
CLIENT_USER="$V23_CLIENT_USER"
CLIENT_PASS="$V23_CLIENT_PASS"
USER_AGENT="${V23_USER_AGENT:-Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36}"

# Occupancy: rooms are separated by ";", each room is <adults>[_<childAge>]...
# (age in years, 1 for an infant; up to 4 children per room)
#   room 1 "2_5_7" -> 2 adults + 2 children aged 5 and 7
#   room 2 "2_3"   -> 2 adults + 1 child aged 3
ROOMS_STRING="2_5_7;2_3"

# Stay dates must be in the future (GNU date, falling back to BSD/macOS date)
CHECK_IN=$(date -d "+30 days" +%F 2>/dev/null || date -v+30d +%F)
CHECK_OUT=$(date -d "+33 days" +%F 2>/dev/null || date -v+33d +%F)

# jget '<python expression>' parses the JSON on stdin as `d` and prints the expression, e.g. jget 'd["searchToken"]'
PY=$(for p in python3 python; do "$p" -c 'import sys; sys.exit(sys.version_info[0] < 3)' 2>/dev/null && echo "$p" && break; done)
[ -n "$PY" ] || { echo "python3 is needed to read the JSON responses" >&2; exit 1; }
jget() {
  "$PY" -c '
import json, sys
raw = sys.stdin.buffer.read()
try:
    out = eval(sys.argv[1], {"d": json.loads(raw), "json": json})
except Exception as e:
    sys.exit("jget: %s: %s\n  expression: %s\n  response: %.300s" % (type(e).__name__, e, sys.argv[1], raw.decode("utf-8", "replace")))
sys.stdout.buffer.write((str(out) + "\n").encode("utf-8"))
' "$1"
}

# 1. GetAPIBearer
BEARER=$(curl -s -X GET "$BASE_URL/backend/Account/GetAPIBearer" -A "$USER_AGENT" -u "$CLIENT_USER:$CLIENT_PASS" | tr -d '"')
[ -n "$BEARER" ] || { echo "GetAPIBearer returned no token - check V23_BASE_URL, V23_CLIENT_USER and V23_CLIENT_PASS" >&2; exit 1; }
echo "1. GetAPIBearer: ok"

# 2. GetGooglePrediction
PLACE_ID=$(curl -s -X POST "$BASE_URL/backend/Utils/GetGooglePrediction" -A "$USER_AGENT" \
  -H "Authorization: Bearer $BEARER" -H "Content-Type: application/json" \
  -d '{"query": "Berlin, Germany", "prefix": "htl"}' \
  | jget 'json.loads(d["googleResponse"])["predictions"][0]["place_id"]')
echo "2. GetGooglePrediction: place_id=$PLACE_ID"

# 3. GetGooglePredictionDetails
DETAILS=$(curl -s -X POST "$BASE_URL/backend/Utils/GetGooglePredictionDetails" -A "$USER_AGENT" \
  -H "Authorization: Bearer $BEARER" -H "Content-Type: application/json" \
  -d "{\"placeId\": \"$PLACE_ID\"}")
CITY=$(printf '%s' "$DETAILS" | jget 'json.loads(d["googleResponse"])["result"]["name"]')
COUNTRY_CODE=$(printf '%s' "$DETAILS" | jget 'next(c["short_name"] for c in json.loads(d["googleResponse"])["result"]["address_components"] if "country" in c["types"])')
LAT=$(printf '%s' "$DETAILS" | jget 'json.loads(d["googleResponse"])["result"]["geometry"]["location"]["lat"]')
LON=$(printf '%s' "$DETAILS" | jget 'json.loads(d["googleResponse"])["result"]["geometry"]["location"]["lng"]')
echo "3. GetGooglePredictionDetails: $CITY / $COUNTRY_CODE / $LAT / $LON"

# 4. BeginHotelSearch - roomsString carries the occupancy: 2 rooms, 4 adults, children aged 5, 7 and 3
SEARCH=$(curl -s -X POST "$BASE_URL/backend/Hotels/BeginHotelSearch" -A "$USER_AGENT" \
  -H "Authorization: Bearer $BEARER" -H "Content-Type: application/json" \
  -d "{\"checkIn\": \"$CHECK_IN\", \"checkOut\": \"$CHECK_OUT\", \"starRating\": 0, \
       \"nationality\": \"IL\", \"searchRadius\": 8, \"roomsString\": \"$ROOMS_STRING\", \"recaptchaToken\": \"\", \
       \"city\": \"$CITY\", \"id\": \"$COUNTRY_CODE\", \"lat\": $LAT, \"lon\": $LON}")
SEARCH_TOKEN=$(printf '%s' "$SEARCH" | jget 'd["searchToken"]')
SYS_TOKEN=$(printf '%s' "$SEARCH" | jget 'd["sysToken"]')
echo "4. BeginHotelSearch: $CHECK_IN -> $CHECK_OUT, roomsString=$ROOMS_STRING, searchToken=$SEARCH_TOKEN"

# 5. GetHotels - call repeatedly (every 1-2s) until poolingFinished=true.
#    Each response only holds the hotels that arrived since the previous call.
HOTELS=""; TOTAL=0
for _ in $(seq 60); do
  RESP=$(curl -s -X POST "$BASE_URL/backend/Hotels/GetHotels" -A "$USER_AGENT" \
    -H "Authorization: Bearer $BEARER" -H "Content-Type: application/json" \
    -d "{\"searchToken\": \"$SEARCH_TOKEN\", \"sysToken\": \"$SYS_TOKEN\"}")
  [ "$(printf '%s' "$RESP" | jget 'd["sessionExpired"]')" = True ] && { echo "the search session expired - run the script again" >&2; exit 1; }
  NEW=$(printf '%s' "$RESP" | jget 'len(d["hotels"] or [])')
  TOTAL=$((TOTAL + NEW))
  echo "5. GetHotels: +$NEW hotels ($TOTAL so far)"
  if [ -z "$HOTELS" ] && [ "$NEW" -gt 0 ]; then HOTELS="$RESP"; fi
  [ "$(printf '%s' "$RESP" | jget 'd["poolingFinished"]')" = True ] && break
  sleep 2
done
[ -n "$HOTELS" ] || { echo "no hotels returned for this search" >&2; exit 1; }
# -> every offer (roomClasses[]) has one hotelRooms[] row per room - two here. The rows come in the supplier's
#    order, which can differ from roomsString; numAdt/numCnn tell the rooms apart. Each row has its own bToken.
echo "   first hotels: name | price of the first offer | its rooms (A = adults, C = children)"
printf '%s' "$HOTELS" | jget '"\n".join("   %s | %.2f %s | %s" % (h["item"]["name"], h["roomClasses"][0]["price"]["value"], h["roomClasses"][0]["price"]["currency"], " + ".join("%dA+%dC" % (r["numAdt"], r["numCnn"]) for r in h["roomClasses"][0]["hotelRooms"])) for h in d["hotels"][:5])'
# -> follow the first hotel and its first offer
HOTEL_UKEY=$(printf '%s' "$HOTELS" | jget 'd["hotels"][0]["htuKey"]')
HOTEL_ITEM_CODE=$(printf '%s' "$HOTELS" | jget 'd["hotels"][0]["item"]["code"]')
ROOM1_BTOKEN=$(printf '%s' "$HOTELS" | jget 'd["hotels"][0]["roomClasses"][0]["hotelRooms"][0]["bToken"]')
ROOM2_BTOKEN=$(printf '%s' "$HOTELS" | jget 'd["hotels"][0]["roomClasses"][0]["hotelRooms"][1]["bToken"]')
SEARCH_PRICE=$(printf '%s' "$HOTELS" | jget '"%.2f %s" % (d["hotels"][0]["roomClasses"][0]["price"]["value"], d["hotels"][0]["roomClasses"][0]["price"]["currency"])')
echo "   -> continuing with: $(printf '%s' "$HOTELS" | jget 'd["hotels"][0]["item"]["name"]') ($SEARCH_PRICE)"

# Steps 6-8 send the bTokens via stdin (-d @-, name@-) rather than as command-line arguments:
# bTokens contain "‡" (U+2021) and Windows curl.exe (Git Bash) converts non-ASCII arguments to the
# ANSI code page, corrupting the token. On Linux/macOS a plain -d "..." / name=value works as well.

# 6. HotelInfo (query params, no body) - one room's bToken is enough
printf %s "$ROOM1_BTOKEN" | curl -s -X POST "$BASE_URL/backend/Hotels/HotelInfo" -G -A "$USER_AGENT" \
  -H "Authorization: Bearer $BEARER" \
  --data-urlencode "searchToken=$SEARCH_TOKEN" \
  --data-urlencode "hotelUkey=$HOTEL_UKEY" \
  --data-urlencode "RoomBToken@-" \
  | jget '"6. HotelInfo: hasErrors=%s, %d images" % (d.get("hasErrors"), len((d.get("hotelDetails") or {}).get("images") or []))'

# 7. ChargeConditions - send the bToken of every room
curl -s -X POST "$BASE_URL/backend/Hotels/ChargeConditions" -A "$USER_AGENT" \
  -H "Authorization: Bearer $BEARER" -H "Content-Type: application/json" \
  -d @- <<< "{\"searchToken\": \"$SEARCH_TOKEN\", \"roomBTokenList\": [\"$ROOM1_BTOKEN\", \"$ROOM2_BTOKEN\"], \"language\": \"He\"}" \
  | jget '"7. ChargeConditions: hasErrors=%s, cancellation limit %s" % (d.get("hasErrors"), (d.get("cancellationPolicy") or {}).get("cancellationLimitDate"))'

# 8. BeginOneHotelSearch - multiRoomsBTokens lists the bToken of EVERY room, roomBToken first
#    (the single-room example sends an empty list here)
ONE_HOTEL_TOKEN=$(curl -s -X POST "$BASE_URL/backend/Hotels/BeginOneHotelSearch" -A "$USER_AGENT" \
  -H "Authorization: Bearer $BEARER" -H "Content-Type: application/json" \
  -d @- <<< "{\"searchToken\": \"$SEARCH_TOKEN\", \"hotels\": [{\"roomBToken\": \"$ROOM1_BTOKEN\", \
       \"hotelItemCode\": \"$HOTEL_ITEM_CODE\", \"multiRoomsBTokens\": [\"$ROOM1_BTOKEN\", \"$ROOM2_BTOKEN\"]}]}" \
  | jget 'd["searchToken"]')
echo "8. BeginOneHotelSearch: secondary searchToken=$ONE_HOTEL_TOKEN"

# 9. GetOneHotelSearchData - poll until poolingFinished=true
for _ in $(seq 30); do
  RECHECK=$(curl -s -X POST "$BASE_URL/backend/Hotels/GetOneHotelSearchData" -A "$USER_AGENT" \
    -H "Authorization: Bearer $BEARER" -H "Content-Type: application/json" \
    -d "{\"searchToken\": \"$ONE_HOTEL_TOKEN\"}")
  [ "$(printf '%s' "$RECHECK" | jget 'd["poolingFinished"]')" = True ] && break
  sleep 2
done
# -> the re-checked hotel is a new result: use ITS htuKey and roomClasses[].rcUniqueKey (the 2-room offer) from here on
if [ "$(printf '%s' "$RECHECK" | jget 'len(d["hotels"] or [])')" = 0 ]; then
  echo "9. GetOneHotelSearchData: the room is no longer available after the live re-check - run the script again"
  exit 0
fi
HOTEL_UKEY=$(printf '%s' "$RECHECK" | jget 'd["hotels"][0]["hotel"]["htuKey"]')
ROOM_ID=$(printf '%s' "$RECHECK" | jget 'd["hotels"][0]["hotel"]["roomClasses"][0]["rcUniqueKey"]')
echo "9. GetOneHotelSearchData: price now $(printf '%s' "$RECHECK" | jget '"%.2f %s" % (d["hotels"][0]["hotel"]["roomClasses"][0]["price"]["value"], d["hotels"][0]["hotel"]["roomClasses"][0]["price"]["currency"])') (search price $SEARCH_PRICE), roomId=$ROOM_ID"

if [ -n "$V23_SKIP_BOOK" ]; then echo "V23_SKIP_BOOK is set - stopping before Book (no order created)"; exit 0; fi

# 10. Book (query params, no body) - HELD, unpaid, unconfirmed
curl -s -X POST "$BASE_URL/backend/Hotels/Book" -G -A "$USER_AGENT" \
  -H "Authorization: Bearer $BEARER" \
  --data-urlencode "hotelUkey=$HOTEL_UKEY" \
  --data-urlencode "searchToken=$ONE_HOTEL_TOKEN" \
  --data-urlencode "roomId=$ROOM_ID" \
  --data-urlencode "Language=He" \
  --data-urlencode "afterOneHotelSearch=true" \
  | jget '"10. Book: orderId=%s, hasErrors=%s %s" % (d.get("orderId"), d.get("hasErrors"), d.get("errorMessage") or "")'
# -> do NOT call BookComplete unless you mean to confirm a real booking. It would need all 7 guests in paxes:
#    4 x ADT + 3 x CNN, each child's dob matching the age searched (5, 7, 3) - see "Request for 1 Adult 3 children
#    Example" on the BookComplete wiki page.
