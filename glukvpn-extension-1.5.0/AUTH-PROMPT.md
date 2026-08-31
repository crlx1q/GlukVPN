# Мини-промпт для агента, который делает сайт (vpn.gluk.tech)

> Скопируй всё, что ниже разделителя, в задачу другому агенту.

---

Ты работаешь в монорепозитории **GlukVPN** (`control-server/` — Node + Prisma + TypeScript,
`site/` — статический сайт). Нужно реализовать **вход по ссылке для внешних клиентов**
(браузерное расширение, будущая программа для ПК) — так, как это сделано в Discord.

Это стандартный **OAuth 2.0 Device Authorization Grant (RFC 8628)**, адаптированный под
наш сайт. Никакого перехвата токенов из localStorage быть не должно.

## Как это выглядит для человека

1. В расширении/программе пользователь жмёт «Войти».
2. Клиент получает от сервера короткий код и ссылку и открывает вкладку
   `https://vpn.gluk.tech/auth/XXXXXXXX`.
3. Если на сайте он уже авторизован — видит карточку «Разрешить доступ **GlukVPN Extension**
   (Chrome, Windows)?» с кнопками **Авторизовать** / **Отклонить**.
4. Если не авторизован — сначала обычный вход, потом его возвращает на ту же карточку.
5. Нажал «Авторизовать» → клиент сам получает токены и входит. Пароль в клиент не вводится.

## 1. Схема БД (`control-server/prisma/schema.prisma`)

```prisma
enum DeviceAuthStatus {
  PENDING
  APPROVED
  DENIED
  EXPIRED
  CLAIMED
}

model DeviceAuthRequest {
  id           String           @id @default(cuid())
  deviceCode   String           @unique   // 32 случайных байта, base64url, знает только клиент
  userCodeHash String           @unique   // SHA-256 от userCode, в открытом виде не храним
  status       DeviceAuthStatus @default(PENDING)
  clientType   String                     // "extension" | "desktop"
  clientName   String                     // "Chrome on Windows"
  ipAddress    String?
  userAgent    String?
  userId       String?                    // проставляется при одобрении
  user         User?            @relation(fields: [userId], references: [id], onDelete: Cascade)
  expiresAt    DateTime                   // now + 10 минут
  approvedAt   DateTime?
  claimedAt    DateTime?                  // токены забрали — повторно нельзя
  createdAt    DateTime         @default(now())

  @@index([status, expiresAt])
}
```

## 2. Эндпоинты (`control-server/src/routes/deviceAuth.ts`)

Все ответы — в существующем формате ошибок `{ "error": { "code": "...", "message": "..." } }`.

### `POST /api/auth/device/start` — без авторизации, лимит 10/мин на IP

```jsonc
// запрос
{ "clientType": "extension", "clientName": "Chrome on Windows" }
// ответ 201
{
  "deviceCode": "<43 символа base64url>",
  "userCode": "KZ7P-4M2Q",
  "verificationUrl": "https://vpn.gluk.tech/auth/KZ7P-4M2Q",
  "expiresIn": 600,
  "interval": 3
}
```

`userCode` — 8 символов из алфавита `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`
(без `I`, `O`, `0`, `1`), формат `XXXX-XXXX`. В базе — только SHA-256.

### `POST /api/auth/device/token` — без авторизации, лимит 30/мин на IP

```jsonc
{ "deviceCode": "..." }
```

Ответы:

| Ситуация | HTTP | `error.code` |
|---|---|---|
| Ещё не подтвердили | 428 | `AUTHORIZATION_PENDING` |
| Опрашивают чаще `interval` | 429 | `SLOW_DOWN` |
| Отклонено | 403 | `ACCESS_DENIED` |
| Истёк / уже забрали | 410 | `EXPIRED_TOKEN` |
| Готово | 200 | — |

При успехе — **тот же payload, что у `POST /api/auth/login`**
(`tokenType`, `accessToken`, `expiresIn`, `refreshToken`, `refreshTokenExpiresAt`,
`user`, `subscription`). Сразу ставим `status = CLAIMED`, `claimedAt = now()`.
Повторный вызов с тем же `deviceCode` обязан вернуть `EXPIRED_TOKEN`.

### `GET /api/auth/device/pending?userCode=KZ7P-4M2Q` — нужна сессия сайта

Отдаёт данные для карточки подтверждения:
`{ "clientType": "extension", "clientName": "Chrome on Windows", "ipAddress": "...", "expiresAt": "..." }`.

### `POST /api/auth/device/approve` и `POST /api/auth/device/deny` — нужна сессия сайта

`{ "userCode": "KZ7P-4M2Q" }` → `{ "ok": true }`.
При одобрении проставляем `userId` из сессии, `status = APPROVED`, `approvedAt = now()`.

## 3. Страница сайта `site/auth/index.html` (+ `site/en/auth/index.html`)

- Роутинг: `/auth/:userCode` (на статике — через `404.html` → редирект, либо правило в nginx
  `try_files`; посмотри, как уже сделаны `site/login/` и `site/account/`).
- Нет сессии → `/login/?next=/auth/KZ7P-4M2Q`, после входа вернуть обратно.
- Есть сессия → `GET /api/auth/device/pending`, показать карточку:
  иконка клиента, название (`clientName`), IP, срок действия, кнопки
  **Авторизовать** / **Отклонить**.
- После ответа — экран «Готово, можно вернуться в приложение».
- Обработать `EXPIRED_TOKEN` и неизвестный код отдельным сообщением.
- Вёрстка и стили — строго существующие (`site/assets/css/components.css`,
  токены и типографика как на `site/account/`). Ничего нового не рисуй.
- Обе локали: `site/auth/` (ru) и `site/en/auth/` (en).

## 4. Безопасность — обязательно

- TTL 10 минут, фоновая чистка `EXPIRED`.
- `deviceCode` — только в ответе `start`, в URL и в логи не попадает.
- `userCode` одноразовый; после `CLAIMED`/`DENIED` не переиспользуется.
- На `approve`/`deny` — CSRF-защита как на остальных POST сайта.
- Лимиты: `start` 10/мин на IP, `token` 30/мин на IP, `approve` 20/мин на пользователя.
- В `GET /api/auth/device/pending` не отдавать ничего о владельце запроса.
- Одобрение привязывает запрос к пользователю сессии; сменил аккаунт — код недействителен.

## 5. Что не трогать

- Существующие `POST /api/auth/login`, `/refresh`, `/logout`, `/me` остаются как есть —
  вход по паролю никуда не девается.
- Реестр устройств (`POST /api/devices/register`) не меняется: клиент вызывает его
  уже после того, как получил токены.

## 6. Готово, когда

- `npx prisma migrate dev` создаёт таблицу без ошибок.
- `npm test` в `control-server/` проходит; добавлены тесты на все пять состояний `token`.
- Ручная проверка: `start` → открыть ссылку → одобрить → `token` отдал токены →
  повторный `token` вернул `EXPIRED_TOKEN`.
- `tsc --noEmit` чистый.

---

### Что уже готово со стороны расширения

В расширении вход по сайту сейчас работает через мост на странице `vpn.gluk.tech`
(`content/site-bridge.js`). Когда эндпоинты выше появятся, переключение делается в
`lib/api.js` + `background.js`, обработчик `linkWithSite`: вместо открытия `/login/`
вызвать `start`, открыть `verificationUrl`, опрашивать `token` каждые `interval` секунд.
Мост после этого можно удалить.
