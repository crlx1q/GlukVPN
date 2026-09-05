import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'

const api = await readFile(new URL('../lib/api.js', import.meta.url), 'utf8')
assert.match(api, /constructor\(\{ statusCode, code, message, retryAfterSec, details \}\)/)
assert.match(api, /this\.details = details/)
assert.match(api, /activeMap: \(\) => request\('GET', '\/api\/user\/active-map'\)/)
assert.match(api, /serviceStatus: \(\) => request\('GET', '\/api\/service\/status'/)

const background = await readFile(new URL('../background.js', import.meta.url), 'utf8')
assert.match(background, /error\.code === 'device_limit_reached'/)
assert.doesNotMatch(background, /if \(error\.isConflict\)[\s\S]{0,120}'limit'/)
assert.match(background, /connectIntent/)
assert.match(background, /MAINTENANCE_ALARM/)
assert.match(background, /safeError/)

const popup = await readFile(new URL('../ui/popup.js', import.meta.url), 'utf8')
assert.match(popup, /String\(normalizedError\(error\)\?\.code/)
assert.match(popup, /openDeviceLimitModal/)
assert.match(popup, /renderAccountMap/)
assert.match(popup, /restrictionLabel/)
console.log('Sprint 2 extension contracts: ok')
