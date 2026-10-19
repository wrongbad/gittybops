// GitHub push webhook -> touch /run/www-hook/<site>, which www-deploy@<site>.path turns into a deploy.
// Only the repo name and ref are read from the (signed) payload; the deploy fetches from git itself,
// so the worst a request can do is make a site redeploy what is already on its branch.
import http from 'node:http'
import crypto from 'node:crypto'
import { readFileSync, readdirSync, watch, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const secret = readFileSync(join(process.env.CREDENTIALS_DIRECTORY, 'secret'), 'utf8').trim()
const runDir = process.env.RUNTIME_DIRECTORY
const siteDir = '/www/gittybops/site'

// When setup replaces this file, exit, and systemd starts the new one.
watch(fileURLToPath(import.meta.url), () => process.exit())

// Sites deployed from "owner/repo refs/heads/branch" (one repo can back several, e.g. prod and staging).
// Read on every request, so setup's changes need no restart.
function sitesFor(key) {
  return readdirSync(siteDir).filter((name) => {
    const [repo, branch] = readFileSync(join(siteDir, name), 'utf8').split(/\s+/)
    const m = repo.match(/github\.com[:/](.+?)(\.git)?$/)
    return m && `${m[1].toLowerCase()} refs/heads/${branch}` === key
  })
}

http.createServer((req, res) => {
  const chunks = []
  let size = 0
  req.on('data', (c) => {
    size += c.length
    if (size > 1 << 20) req.destroy()
    else chunks.push(c)
  })
  req.on('end', () => {
    const body = Buffer.concat(chunks)
    const want = Buffer.from('sha256=' + crypto.createHmac('sha256', secret).update(body).digest('hex'))
    const got = Buffer.from(String(req.headers['x-hub-signature-256'] ?? ''))
    if (got.length !== want.length || !crypto.timingSafeEqual(got, want)) return res.writeHead(401).end()
    let key = ''
    try {
      const p = JSON.parse(body)
      key = `${p.repository.full_name.toLowerCase()} ${p.ref}`
    } catch {} // ping events and non-push payloads just match nothing
    const names = sitesFor(key)
    for (const name of names) writeFileSync(join(runDir, name), `${Date.now()}\n`)
    res.writeHead(202).end(`${names.join(' ') || 'no site'}\n`)
  })
}).listen(9000, '127.0.0.1')
