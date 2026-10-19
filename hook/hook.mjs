// GitHub push webhook -> touch /run/www-hook/<site>, which www-deploy@<site>.path turns into a deploy.
// Only the repo name and ref are read from the (signed) payload; the deploy fetches from git itself,
// so the worst a request can do is make a site redeploy what is already on its branch.
import http from 'node:http'
import crypto from 'node:crypto'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const secret = readFileSync(join(process.env.CREDENTIALS_DIRECTORY, 'secret'), 'utf8').trim()
const runDir = process.env.RUNTIME_DIRECTORY

// "owner/repo refs/heads/branch" -> site names (one repo can back several sites, e.g. prod and staging)
const sites = new Map()
for (const line of readFileSync('/www/live/sites.conf', 'utf8').split('\n')) {
  const [name, repo, branch] = line.replace(/#.*/, '').trim().split(/\s+/)
  const m = branch && repo.match(/github\.com[:/](.+?)(\.git)?$/)
  if (!m) continue
  const key = `${m[1].toLowerCase()} refs/heads/${branch}`
  sites.set(key, [...(sites.get(key) ?? []), name])
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
    const names = sites.get(key) ?? []
    for (const name of names) writeFileSync(join(runDir, name), `${Date.now()}\n`)
    res.writeHead(202).end(`${names.join(' ') || 'no site'}\n`)
  })
}).listen(9000, '127.0.0.1')
