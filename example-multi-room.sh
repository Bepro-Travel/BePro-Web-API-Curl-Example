#!/usr/bin/env bash
# Multi-room variant of example.sh: 2 rooms, 4 adults, 3 children (aged 5, 7 and 3).
# Raw sequential requests — run one, read the JSON response, copy the value you need into the
# matching shell variable, run the next. No JSON parsing shown here for brevity; use `jq` in a
# real script.
# Multi-room differences from example.sh: ROOMS_STRING (step 4), one bToken per room in step 5,
# and both bTokens sent in steps 7 and 8.
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

# 1. GetAPIBearer
BEARER=$(curl -s -X GET "$BASE_URL/backend/Account/GetAPIBearer" -A "$USER_AGENT" -u "$CLIENT_USER:$CLIENT_PASS" | tr -d '"')

# 2. GetGooglePrediction
curl -s -X POST "$BASE_URL/backend/Utils/GetGooglePrediction" -A "$USER_AGENT" \
  -H "Authorization: Bearer $BEARER" -H "Content-Type: application/json" \
  -d '{"query": "Berlin, Germany", "prefix": "htl"}'
# -> take googleResponse.predictions[0].place_id
PLACE_ID="..."

# 3. GetGooglePredictionDetails
curl -s -X POST "$BASE_URL/backend/Utils/GetGooglePredictionDetails" -A "$USER_AGENT" \
  -H "Authorization: Bearer $BEARER" -H "Content-Type: application/json" \
  -d "{\"placeId\": \"$PLACE_ID\"}"
# -> take city / countryCode / lat / lon from googleResponse.result
CITY="..." ; COUNTRY_CODE="..." ; LAT="..." ; LON="..."

# 4. BeginHotelSearch - roomsString carries the occupancy: 2 rooms, 4 adults, children aged 5, 7 and 3
curl -s -X POST "$BASE_URL/backend/Hotels/BeginHotelSearch" -A "$USER_AGENT" \
  -H "Authorization: Bearer $BEARER" -H "Content-Type: application/json" \
  -d "{\"checkIn\": \"$CHECK_IN\", \"checkOut\": \"$CHECK_OUT\", \"starRating\": 0, \
       \"nationality\": \"IL\", \"searchRadius\": 8, \"roomsString\": \"$ROOMS_STRING\", \"recaptchaToken\": \"\", \
       \"city\": \"$CITY\", \"id\": \"$COUNTRY_CODE\", \"lat\": $LAT, \"lon\": $LON}"
# -> searchToken, sysToken
SEARCH_TOKEN="..." ; SYS_TOKEN="..."

# 5. GetHotels - call repeatedly (every 1-2s) until poolingFinished=true
curl -s -X POST "$BASE_URL/backend/Hotels/GetHotels" -A "$USER_AGENT" \
  -H "Authorization: Bearer $BEARER" -H "Content-Type: application/json" \
  -d "{\"searchToken\": \"$SEARCH_TOKEN\", \"sysToken\": \"$SYS_TOKEN\"}"
# -> pick a hotel -> hotelUkey (htuKey) ; item.code -> hotelItemCode
# -> pick a roomClasses[] entry whose hotelRooms[] has one row per room (two here); its rcUniqueKey
#    identifies the whole 2-room offer. Take each row's bToken, matching rows to rooms by occupancy
#    rather than by array position:
#      room 1 (2 adults + 2 children): numAdt=2, numCnn=2 (sysCode O2A2C)
#      room 2 (2 adults + 1 child):    numAdt=2, numCnn=1 (sysCode O2A1C)
HOTEL_UKEY="..." ; HOTEL_ITEM_CODE="..."
ROOM1_BTOKEN="..." ; ROOM2_BTOKEN="..."

# Steps 6-8 send the bTokens via stdin (-d @-, name@-) rather than as command-line arguments:
# bTokens contain "‡" (U+2021) and Windows curl.exe (Git Bash) converts non-ASCII arguments to the
# ANSI code page, corrupting the token. On Linux/macOS a plain -d "..." / name=value works as well.

# 6. HotelInfo (query params, no body) - one room's bToken is enough
printf %s "$ROOM1_BTOKEN" | curl -s -X POST "$BASE_URL/backend/Hotels/HotelInfo" -G -A "$USER_AGENT" \
  -H "Authorization: Bearer $BEARER" \
  --data-urlencode "searchToken=$SEARCH_TOKEN" \
  --data-urlencode "hotelUkey=$HOTEL_UKEY" \
  --data-urlencode "RoomBToken@-"

# 7. ChargeConditions - send the bToken of every room
curl -s -X POST "$BASE_URL/backend/Hotels/ChargeConditions" -A "$USER_AGENT" \
  -H "Authorization: Bearer $BEARER" -H "Content-Type: application/json" \
  -d @- <<< "{\"searchToken\": \"$SEARCH_TOKEN\", \"roomBTokenList\": [\"$ROOM1_BTOKEN\", \"$ROOM2_BTOKEN\"], \"language\": \"He\"}"

# 8. BeginOneHotelSearch - multiRoomsBTokens lists the bToken of EVERY room, roomBToken first
#    (the single-room example sends an empty list here)
curl -s -X POST "$BASE_URL/backend/Hotels/BeginOneHotelSearch" -A "$USER_AGENT" \
  -H "Authorization: Bearer $BEARER" -H "Content-Type: application/json" \
  -d @- <<< "{\"searchToken\": \"$SEARCH_TOKEN\", \"hotels\": [{\"roomBToken\": \"$ROOM1_BTOKEN\", \
       \"hotelItemCode\": \"$HOTEL_ITEM_CODE\", \"multiRoomsBTokens\": [\"$ROOM1_BTOKEN\", \"$ROOM2_BTOKEN\"]}]}"
# -> secondary searchToken
ONE_HOTEL_TOKEN="..."

# 9. GetOneHotelSearchData - poll until poolingFinished=true
curl -s -X POST "$BASE_URL/backend/Hotels/GetOneHotelSearchData" -A "$USER_AGENT" \
  -H "Authorization: Bearer $BEARER" -H "Content-Type: application/json" \
  -d "{\"searchToken\": \"$ONE_HOTEL_TOKEN\"}"
# -> refreshed hotelUkey (hotel.htuKey) and roomId (roomClasses[].rcUniqueKey, the 2-room offer); "" if none
HOTEL_UKEY="..." ; ROOM_ID="..."

# 10. Book (query params, no body) - HELD, unpaid, unconfirmed
curl -s -X POST "$BASE_URL/backend/Hotels/Book" -G -A "$USER_AGENT" \
  -H "Authorization: Bearer $BEARER" \
  --data-urlencode "hotelUkey=$HOTEL_UKEY" \
  --data-urlencode "searchToken=$ONE_HOTEL_TOKEN" \
  --data-urlencode "roomId=$ROOM_ID" \
  --data-urlencode "Language=He" \
  --data-urlencode "afterOneHotelSearch=true"
# -> orderId (do NOT call BookComplete unless you mean to confirm a real booking)
# BookComplete would then need all 7 guests in paxes: 4 x ADT + 3 x CNN, each child's dob matching the
# age searched (5, 7, 3) - see "Request for 1 Adult 3 children Example" on the BookComplete wiki page.
