# BePro Web API — cURL Example

Raw sequential `curl` requests walking through the full [BePro Hotel Search & Booking API](https://github.com/Bepro-Travel/BePro-Web-API/wiki) flow — steps 1–10 (everything up to, but not including, `BookComplete`, which is left for you to call deliberately once you've reviewed [BookComplete](https://github.com/Bepro-Travel/BePro-Web-API/wiki/BookComplete)).

Run one request, read the JSON response, copy the value you need into the matching shell variable, then run the next. No JSON parsing is shown here for brevity — use `jq` in a real script.

## Prerequisites

| Setting | Meaning |
|---|---|
| `V23_BASE_URL` | Base URL of the API for your account, e.g. `https://your_company.beprotravel.com` (no trailing slash) |
| `V23_CLIENT_USER` / `V23_CLIENT_PASS` | Basic Auth credentials for [`GetAPIBearer`](https://github.com/Bepro-Travel/BePro-Web-API/wiki/GetAPIBearer), issued to you separately |
| User-Agent | Must look like a real browser (see [Authentication & Setup](https://github.com/Bepro-Travel/BePro-Web-API/wiki/Authentication-and-Setup)) |

Never hard-code these values into source you commit anywhere — pass them as environment variables, as shown below.

## Setup

```bash
export V23_BASE_URL="https://your_company.beprotravel.com"
export V23_CLIENT_USER="..."
export V23_CLIENT_PASS="..."

bash example.sh
```

The script stops after printing the `10. Book` response (a held, unpaid booking) — fill in the placeholder variables (`PLACE_ID`, `SEARCH_TOKEN`, `HOTEL_UKEY`, etc.) with values from each preceding response as you go.

## Full API documentation

See the [BePro Web API wiki](https://github.com/Bepro-Travel/BePro-Web-API/wiki) for the full endpoint reference, request/response shapes, and conventions.
