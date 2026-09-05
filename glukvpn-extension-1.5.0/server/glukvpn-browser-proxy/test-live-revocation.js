'use strict'
const assert = require('node:assert/strict')
const http = require('node:http')
const net = require('node:net')
const { spawn } = require('node:child_process')
const path = require('node:path')

const CONTROL_PORT = 19081
const TARGET_PORT = 19082
const PROXY_PORT = 19083
let mode = 'connected'

const control = http.createServer((req, res) => {
  if (req.url !== '/api/vpn/status') return res.writeHead(404).end()
  if (mode === 'maintenance') {
    res.writeHead(200, { 'content-type': 'application/json' })
    return res.end(JSON.stringify({ connected: true, subscriptionActive: true, service: { maintenance: true } }))
  }
  res.writeHead(200, { 'content-type': 'application/json' })
  res.end(JSON.stringify({ connected: mode === 'connected', subscriptionActive: true, service: { maintenance: false } }))
})
const target = net.createServer(() => {})

function listen(server, port) {
  return new Promise((resolve, reject) => server.listen(port, '127.0.0.1', resolve).once('error', reject))
}
function wait(ms) { return new Promise((resolve) => setTimeout(resolve, ms)) }
function connectRequest() {
  return new Promise((resolve, reject) => {
    const socket = net.connect(PROXY_PORT, '127.0.0.1')
    let data = ''
    socket.setEncoding('utf8')
    socket.once('error', reject)
    socket.on('data', (chunk) => {
      data += chunk
      if (data.includes('\r\n\r\n')) resolve({ socket, data })
    })
    socket.once('connect', () => {
      const token = 'e30.' + Buffer.from(JSON.stringify({ sub: 'user-1' })).toString('base64url') + '.sig'
      const basic = Buffer.from(`device-1:${token}`).toString('base64')
      socket.write(`CONNECT 127.0.0.1:${TARGET_PORT} HTTP/1.1\r\nHost: 127.0.0.1:${TARGET_PORT}\r\nProxy-Authorization: Basic ${basic}\r\n\r\n`)
    })
  })
}
function closedWithin(socket, timeoutMs) {
  return Promise.race([
    new Promise((resolve) => socket.once('close', () => resolve(true))),
    wait(timeoutMs).then(() => false),
  ])
}

;(async () => {
  await Promise.all([listen(control, CONTROL_PORT), listen(target, TARGET_PORT)])
  const child = spawn(process.execPath, [path.join(__dirname, 'src/server.js')], {
    env: {
      ...process.env,
      NODE_ENV: 'test',
      ALLOW_INSECURE_HTTP: 'true',
      ALLOW_TEST_LOOPBACK_TARGET: 'true',
      BIND_HOST: '127.0.0.1',
      PORT: String(PROXY_PORT),
      CONTROL_API: `http://127.0.0.1:${CONTROL_PORT}`,
      ALLOWED_PORTS: String(TARGET_PORT),
      REVALIDATE_INTERVAL_MS: '5000',
      AUTH_CACHE_TTL_MS: '60000',
      LOG_LEVEL: 'error',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  try {
    await wait(500)
    const first = await connectRequest()
    assert.match(first.data, /^HTTP\/1\.1 200 /)
    mode = 'disconnected'
    assert.equal(await closedWithin(first.socket, 7500), true, 'revoked device tunnel stayed open')

    mode = 'maintenance'
    const second = await connectRequest()
    assert.match(second.data, /^HTTP\/1\.1 503 /)
    second.socket.destroy()
    console.log('browser proxy live revocation checks passed')
  } finally {
    child.kill('SIGTERM')
    control.close()
    target.close()
  }
})().catch((error) => {
  console.error(error)
  process.exitCode = 1
})
