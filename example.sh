#!/usr/bin/env bash
# Raw sequential requests — run one, read the JSON response, copy the value you need into the
# matching shell variable, run the next. No JSON parsing shown here for brevity; use `jq` in a
# real script.
set -e

BASE_URL="$V23_BASE_URL"
CLIENT_USER="$V23_CLIENT_USER"
CLIENT_PASS="$V23_CLIENT_PASS"

# 1. GetAPIBearer
BEARER=$(curl -s -X GET "$BASE_URL/backend/Account/GetAPIBearer" -u "$CLIENT_USER:$CLIENT_PASS" | tr -d '"')

# 2. GetGooglePrediction
curl -s -X POST "$BASE_URL/backend/Utils/GetGooglePrediction" \
  -H "Authorization: Bearer $BEARER" -H "Content-Type: application/json" \
  -d '{"query": "Berlin, Germany", "prefix": "htl"}'
# -> take googleResponse.predictions[0].place_id
PLACE_ID="..."

# 3. GetGooglePredictionDetails
curl -s -X POST "$BASE_URL/backend/Utils/GetGooglePredictionDetails" \
  -H "Authorization: Bearer $BEARER" -H "Content-Type: application/json" \
  -d "{\"placeId\": \"$PLACE_ID\"}"
# -> take city / countryCode / lat / lon from googleResponse.result
CITY="..." ; COUNTRY_CODE="..." ; LAT="..." ; LON="..."

# 4. BeginHotelSearch
curl -s -X POST "$BASE_URL/backend/Hotels/BeginHotelSearch" \
  -H "Authorization: Bearer $BEARER" -H "Content-Type: application/json" \
  -d "{\"checkIn\": \"2026-10-08\", \"checkOut\": \"2026-10-11\", \"starRating\": 0, \
       \"nationality\": \"IL\", \"searchRadius\": 8, \"roomsString\": \"2;\", \"recaptchaToken\": \"\", \
       \"city\": \"$CITY\", \"id\": \"$COUNTRY_CODE\", \"lat\": $LAT, \"lon\": $LON}"
# -> searchToken, sysToken
SEARCH_TOKEN="..." ; SYS_TOKEN="..."

# 5. GetHotels - call repeatedly (every 1-2s) until poolingFinished=true
curl -s -X POST "$BASE_URL/backend/Hotels/GetHotels" \
  -H "Authorization: Bearer $BEARER" -H "Content-Type: application/json" \
  -d "{\"searchToken\": \"$SEARCH_TOKEN\", \"sysToken\": \"$SYS_TOKEN\"}"
# -> pick a hotel -> hotelUkey ; roomClasses[].hotelRooms[0].bToken ; item.hotelItemCode
HOTEL_UKEY="..." ; ROOM_BTOKEN="..." ; HOTEL_ITEM_CODE="..."

# 6. HotelInfo (query params, no body)
curl -s -X POST "$BASE_URL/backend/Hotels/HotelInfo" -G \
  -H "Authorization: Bearer $BEARER" \
  --data-urlencode "searchToken=$SEARCH_TOKEN" \
  --data-urlencode "hotelUkey=$HOTEL_UKEY" \
  --data-urlencode "RoomBToken=$ROOM_BTOKEN"

# 7. ChargeConditions
curl -s -X POST "$BASE_URL/backend/Hotels/ChargeConditions" \
  -H "Authorization: Bearer $BEARER" -H "Content-Type: application/json" \
  -d "{\"searchToken\": \"$SEARCH_TOKEN\", \"roomBTokenList\": [\"$ROOM_BTOKEN\"], \"language\": \"He\"}"

# 8. BeginOneHotelSearch
curl -s -X POST "$BASE_URL/backend/Hotels/BeginOneHotelSearch" \
  -H "Authorization: Bearer $BEARER" -H "Content-Type: application/json" \
  -d "{\"searchToken\": \"$SEARCH_TOKEN\", \"hotels\": [{\"roomBToken\": \"$ROOM_BTOKEN\", \
       \"hotelItemCode\": \"$HOTEL_ITEM_CODE\", \"multiRoomsBTokens\": []}]}"
# -> secondary searchToken
ONE_HOTEL_TOKEN="..."

# 9. GetOneHotelSearchData - poll until poolingFinished=true
curl -s -X POST "$BASE_URL/backend/Hotels/GetOneHotelSearchData" \
  -H "Authorization: Bearer $BEARER" -H "Content-Type: application/json" \
  -d "{\"searchToken\": \"$ONE_HOTEL_TOKEN\"}"
# -> refreshed roomId (rcUniqueKey); "" if none
ROOM_ID="..."

# 10. Book (query params, no body) - HELD, unpaid, unconfirmed
curl -s -X POST "$BASE_URL/backend/Hotels/Book" -G \
  -H "Authorization: Bearer $BEARER" \
  --data-urlencode "hotelUkey=$HOTEL_UKEY" \
  --data-urlencode "searchToken=$ONE_HOTEL_TOKEN" \
  --data-urlencode "roomId=$ROOM_ID" \
  --data-urlencode "Language=He" \
  --data-urlencode "afterOneHotelSearch=true"
# -> orderId (do NOT call BookComplete unless you mean to confirm a real booking)
