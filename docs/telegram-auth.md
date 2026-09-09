# Telegram sign-up and sign-in: one bot, one owner

> Written after the report from TabPay (ROUND 27). Read this before touching
> `TELEGRAM_BOT_TOKEN` on either channel.

## The symptom

On every platform - site, Android, Windows, extension - pressing the Telegram
button produced one of two answers from the bot, at random, on links that were
seconds old:

- `Код не найден или уже истёк.` - sign-up / re-bind (`attachTelegram`, reason `unknown`)
- `Эта ссылка для входа неизвестна или уже истекла.` - sign-in (`handleLoginStart`)

Both strings come from our own bot, which is the important clue: the update
*was* delivered, the bot *was* running, and it looked the code up and did not
find it. Nothing was expiring. The code was in a different database.

## The cause

A Telegram bot token can be long-polled by exactly one process. `getUpdates`
from a second process makes Telegram answer one of them with **409 Conflict**
and hand each individual update to whoever is holding the connection at that
moment.

prod and beta are two full stacks with two separate databases:

| | prod | beta |
| --- | --- | --- |
| service | `glukvpn-control` | `glukvpn-beta-control` |
| port | 8081 | 8082 |
| env | `/etc/glukvpn/control.env` | `/etc/glukvpn/beta-control.env` |
| database | `glukvpn` | `glukvpn_beta` |
| API host | `api.gluk.tech` | `beta-api.gluk.tech` |

`TELEGRAM_BOT_IN_PROCESS` defaults to `true`, so **both** of them started the
bot. With one shared token that means roughly half of all Telegram updates were
answered by the stack that had not issued the code - and a `verificationCode` /
`link_requests` row simply does not exist in the other database.

The deep links made it impossible to notice: `verifyUrl` already carried
`?api=prod|beta`, but `t.me/<bot>?start=<CODE>` carried no channel at all, so
the bot had no way to tell "this code is not mine" from "this code is old".

## The rule

1. `TELEGRAM_BOT_CHANNEL` names the single channel that may poll the token.
   Everyone else keeps the token (it is still needed to *send* messages) and
   never calls `getUpdates` - see `startTelegramBot`, which now logs
   `telegram_bot_disabled_foreign_channel` and returns.
2. Every start payload is tagged with the channel that minted it
   (`<TOKEN>_beta`). A tagged payload arriving at the wrong bot gets a precise
   explanation instead of "not found". Untagged payloads count as local, so
   links issued before this change keep working.
3. Routes ask `telegramUsable()` - token set **and** owned by this channel -
   before offering a Telegram step at all, instead of `telegramConfigured()`.
   A channel that cannot finish the flow no longer starts it.
4. A 409 from Telegram is logged as `telegram_getupdates_conflict` at error
   level. If this line ever appears again, two processes are sharing a token.

`GET /api/auth/config` now reports `telegram.botChannel` and
`telegram.channel`; when they differ, that difference alone is the diagnosis.

## Server actions (required - the code change alone is not enough)

```bash
# prod owns the live bot
sudo sh -c 'echo "TELEGRAM_BOT_CHANNEL=prod" >> /etc/glukvpn/control.env'

# beta must NOT poll the same token. Either give it its own @BotFather bot:
#   TELEGRAM_BOT_TOKEN=<second bot token>
#   TELEGRAM_BOT_USERNAME=<second bot name>
#   TELEGRAM_BOT_CHANNEL=beta
# or leave beta without a bot:
#   TELEGRAM_BOT_TOKEN=
sudo sh -c 'echo "TELEGRAM_BOT_CHANNEL=prod" >> /etc/glukvpn/beta-control.env'

sudo systemctl restart glukvpn-control glukvpn-beta-control
```

Check afterwards:

```bash
# prod: expect telegram.enabled true, botChannel == channel == prod
curl -s https://api.gluk.tech/api/auth/config | jq .telegram

# beta: expect enabled false while it does not own a bot
curl -s https://beta-api.gluk.tech/api/auth/config | jq .telegram

# exactly one process should log telegram_bot_started
sudo journalctl -u glukvpn-control -u glukvpn-beta-control --since "-5 min" \
  | grep -E "telegram_bot_started|telegram_bot_disabled|telegram_getupdates_conflict"
```

## Email, and the other half of the report

`mailerReady()` is `SMTP_HOST && SMTP_USER && SMTP_PASSWORD`. Without
`SMTP_PASSWORD` the registration code was still issued and quietly never sent,
which is exactly "не работает авторизация по почте" from the outside.
`POST /api/auth/register/start` now refuses with 503 when mail is not
configured, so the failure is loud instead of stranding people on step 2.
Make sure the Zoho password is present in `/etc/glukvpn/control.env`.

The phone number is only ever used as a one-human-one-account check: the bot
requires `contact.user_id === message.from.id`, so a forwarded contact cannot
be used, and nothing but the number is stored. It is what keeps the free plan
from being farmed.

## TTLs

| Secret | TTL | Where |
| --- | --- | --- |
| e-mail code | `VERIFICATION_CODE_TTL_MIN` (5 min) | `services/verification.ts` |
| Telegram re-bind token | 15 min | `TELEGRAM_LINK_TTL_MIN`, `services/registration.ts` |
| sign-in link (`XXXX-XXXX`) | 5 min | `TTL_MS`, `services/linkAuth.ts` |
| chat token / chat login | 10 min, in memory | `CHAT_TOKEN_TTL_MS`, `services/telegramBot.ts` |

The re-bind token is deliberately longer than a mailed code: opening Telegram,
pressing start and pressing "share contact" is three app switches on a phone.

## Known follow-ups

- `chatTokens` / `chatLogins` are in-memory, so a deploy restart in the middle
  of a chat loses the "which code is this chat answering for" mapping. Moving
  them into the database (as `link_requests` already is) would remove the last
  way to see "код не найден" during a release.
- If beta ever has to share the prod bot, the owner could forward a foreign
  payload to the peer channel over loopback instead of explaining the mismatch.
