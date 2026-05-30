import { Hono } from 'hono'
import { cors } from 'hono/cors'
import { getDb } from './db/client'
import { marketCandles, computedKeys, sheetKeysSnapshot, discordIntradayLevels } from './db/schema'
import { eq, and, desc, lt, gte } from 'drizzle-orm'
type Env = {
  DB: D1Database
  EA_SECRET: string
  DISCORD_TOKEN: string
  AI: Ai
}

const app = new Hono<{ Bindings: Env }>()

app.use('*', cors({
  origin: '*',
  allowMethods: ['GET', 'POST', 'OPTIONS'],
  allowHeaders: ['Content-Type', 'X-EA-Secret'],
}))

app.use('*', async (c, next) => {
  await next()
  c.res.headers.set('X-Content-Type-Options', 'nosniff')
  c.res.headers.set('Referrer-Policy', 'strict-origin-when-cross-origin')
})

app.get('/health', (c) => c.json({ ok: true }))

// POST /api/market-candles — EA push (requires X-EA-Secret header)
app.post('/api/market-candles', async (c) => {
  const secret = c.req.header('X-EA-Secret')
  if (!secret || secret !== c.env.EA_SECRET) {
    return c.json({ error: 'Unauthorized' }, 401)
  }

  const body = await c.req.json()

  const required = ['symbol', 'timeframe', 'openTime', 'open', 'high', 'low', 'close']
  for (const field of required) {
    if (body[field] === undefined || body[field] === null) {
      return c.json({ error: `Missing field: ${field}` }, 400)
    }
  }

  if (typeof body.symbol !== 'string' || body.symbol.length === 0) {
    return c.json({ error: 'symbol must be a non-empty string' }, 400)
  }
  if (body.open <= 0 || body.high <= 0 || body.low <= 0 || body.close <= 0) {
    return c.json({ error: 'Prices must be > 0' }, 400)
  }
  if (body.rsi !== undefined && body.rsi !== null && (body.rsi < 0 || body.rsi > 100)) {
    return c.json({ error: 'rsi must be 0–100' }, 400)
  }
  if (body.pivot !== undefined && body.pivot !== null && body.pivot <= 0) {
    return c.json({ error: 'pivot must be > 0 (zero means EA cold-start with no daily data)' }, 400)
  }
  if (isNaN(Date.parse(body.openTime))) {
    return c.json({ error: 'openTime must be a valid ISO datetime' }, 400)
  }

  const db = getDb(c.env)

  const vals = {
    symbol:       body.symbol,
    timeframe:    body.timeframe,
    openTime:     body.openTime,
    open:         body.open,
    high:         body.high,
    low:          body.low,
    close:        body.close,
    tickVolume:   body.tickVolume    ?? 0,
    maFast:       body.maFast        ?? null,
    maMid:        body.maMid         ?? null,
    maSlow:       body.maSlow        ?? null,
    maFastPeriod: body.maFastPeriod  ?? null,
    maMidPeriod:  body.maMidPeriod   ?? null,
    maSlowPeriod: body.maSlowPeriod  ?? null,
    maFour:       body.maFour        ?? null,
    maFive:       body.maFive        ?? null,
    maFourPeriod: body.maFourPeriod  ?? null,
    maFivePeriod: body.maFivePeriod  ?? null,
    rsi:          body.rsi           ?? null,
    rsiPeriod:    body.rsiPeriod     ?? null,
    pivot:        body.pivot         ?? null,
    r1:           body.r1            ?? null,
    r2:           body.r2            ?? null,
    r3:           body.r3            ?? null,
    s1:           body.s1            ?? null,
    s2:           body.s2            ?? null,
    s3:           body.s3            ?? null,
    dayOpen:      body.dayOpen       ?? null,
    fibHigh:      body.fibHigh       ?? null,
    fibLow:       body.fibLow        ?? null,
    fib0:         body.fib0          ?? null,
    fib236:       body.fib236        ?? null,
    fib382:       body.fib382        ?? null,
    fib500:       body.fib500        ?? null,
    fib618:       body.fib618        ?? null,
    fib786:       body.fib786        ?? null,
    fib100:       body.fib100        ?? null,
    createdAt:    new Date().toISOString(),
  }

  const { createdAt: _c, symbol: _s, timeframe: _tf, openTime: _ot, ...updateSet } = vals

  await db.insert(marketCandles).values(vals).onConflictDoUpdate({
    target: [marketCandles.symbol, marketCandles.timeframe, marketCandles.openTime],
    set: updateSet,
  })

  console.log(`[market-candles] upsert ${body.symbol} ${body.openTime}`)
  return c.json({ ok: true })
})

const SHEETS_CSV_URL = 'https://docs.google.com/spreadsheets/d/1U3cmUcButtkMjAd23iepwwchJic_oU6k0MUTiLffgCY/export?format=csv&gid=1646559393'

function parseCSVLine(line: string): string[] {
  const result: string[] = []
  let inQ = false, cur = ''
  for (const ch of line) {
    if (ch === '"') { inQ = !inQ }
    else if (ch === ',' && !inQ) { result.push(cur); cur = '' }
    else { cur += ch }
  }
  result.push(cur)
  return result
}

// GET /api/keys — proxy Google Sheets key levels (60s browser cache, CF edge bypassed)
app.get('/api/keys', async (c) => {
  try {
    const fresh = c.req.query('fresh') === '1'
    const url = fresh ? `${SHEETS_CSV_URL}&_t=${Date.now()}` : SHEETS_CSV_URL
    const res = await fetch(url, {
      redirect: 'follow',
      // @ts-expect-error — Cloudflare Workers fetch extension
      cf: { cacheTtl: 0, cacheEverything: false },
    })
    if (!res.ok) return c.json({ error: 'Sheet fetch failed' }, 502)
    const text = await res.text()
    const lines = text.split('\n').filter(l => l.trim())
    // Skip header row; cols 12-16 = M(Intraday), N(H1), O(H4), P(Daily), Q(Week)
    const intradayKeys: number[] = []
    const h1Turn: number[] = []
    const h4Turn: number[] = []
    const dailyTurn: number[] = []
    const weekTurn: number[] = []
    for (let i = 1; i < lines.length; i++) {
      const cols = parseCSVLine(lines[i])
      const parseCol = (idx: number) => { const v = parseFloat(cols[idx]); return isNaN(v) ? null : v }
      const mk = parseCol(12); if (mk != null) intradayKeys.push(mk)
      const n  = parseCol(14); if (n  != null) h1Turn.push(n)
      const o  = parseCol(15); if (o  != null) h4Turn.push(o)
      const p  = parseCol(16); if (p  != null) dailyTurn.push(p)
      const q  = parseCol(17); if (q  != null) weekTurn.push(q)
    }
    c.res.headers.set('Cache-Control', fresh ? 'no-store' : 'public, max-age=60')
    return c.json({ intradayKeys, h1Turn, h4Turn, dailyTurn, weekTurn })
  } catch (e: any) {
    return c.json({ error: e.message }, 502)
  }
})

// POST /api/computed-keys — EA push (requires X-EA-Secret header)
// Body: { symbol, computedAt, bidRef, levels: [{tier, level, side, sourceCount, tierMask?, confluence?}] }
app.post('/api/computed-keys', async (c) => {
  const secret = c.req.header('X-EA-Secret')
  if (!secret || secret !== c.env.EA_SECRET) {
    return c.json({ error: 'Unauthorized' }, 401)
  }

  const body = await c.req.json()

  if (typeof body.symbol !== 'string' || body.symbol.length === 0) {
    return c.json({ error: 'symbol required' }, 400)
  }
  if (typeof body.computedAt !== 'string' || isNaN(Date.parse(body.computedAt))) {
    return c.json({ error: 'computedAt must be ISO datetime' }, 400)
  }
  if (typeof body.bidRef !== 'number' || body.bidRef <= 0) {
    return c.json({ error: 'bidRef must be > 0' }, 400)
  }
  if (!Array.isArray(body.levels) || body.levels.length === 0) {
    return c.json({ error: 'levels must be a non-empty array' }, 400)
  }
  if (body.levels.length > 1000) {
    return c.json({ error: 'too many levels (max 1000)' }, 400)
  }

  const validTiers = new Set(['intraday', 'h1', 'h4', 'd1', 'master'])
  const validSides = new Set(['historical', 'forward'])
  const rows: any[] = []

  for (const lvl of body.levels) {
    if (!validTiers.has(lvl.tier)) {
      return c.json({ error: `invalid tier: ${lvl.tier}` }, 400)
    }
    if (!validSides.has(lvl.side)) {
      return c.json({ error: `invalid side: ${lvl.side}` }, 400)
    }
    if (typeof lvl.level !== 'number' || lvl.level <= 0) {
      return c.json({ error: 'level must be > 0' }, 400)
    }
    if (typeof lvl.sourceCount !== 'number' || lvl.sourceCount < 0) {
      return c.json({ error: 'sourceCount must be >= 0' }, 400)
    }
    rows.push({
      symbol:      body.symbol,
      tier:        lvl.tier,
      level:       lvl.level,
      side:        lvl.side,
      sourceCount: lvl.sourceCount,
      tierMask:    lvl.tierMask   ?? null,
      confluence:  lvl.confluence ?? null,
      bidRef:      body.bidRef,
      computedAt:  body.computedAt,
      createdAt:   new Date().toISOString(),
    })
  }

  const db = getDb(c.env)
  // D1 caps prepared-statement bindings at 100 variables per query.
  // Each row has 11 columns; chunk = 8 rows → 88 params, safe headroom.
  const CHUNK = 8
  try {
    for (let i = 0; i < rows.length; i += CHUNK) {
      const slice = rows.slice(i, i + CHUNK)
      await db.insert(computedKeys).values(slice).onConflictDoNothing()
    }
  } catch (e: any) {
    console.error(`[computed-keys] insert failed: ${e?.message || e}`)
    return c.json({ error: 'Insert failed', detail: e?.message || String(e) }, 500)
  }

  console.log(`[computed-keys] insert ${body.symbol} ${body.computedAt} ${rows.length} rows`)
  return c.json({ ok: true, count: rows.length })
})

// GET /api/computed-keys?symbol=XAUUSD[&tier=master][&since=ISO]
app.get('/api/computed-keys', async (c) => {
  const symbol = c.req.query('symbol')
  const tier   = c.req.query('tier')
  const since  = c.req.query('since')
  if (!symbol) return c.json({ error: 'symbol required' }, 400)

  const db = getDb(c.env)
  const conditions = [eq(computedKeys.symbol, symbol)]
  if (tier)  conditions.push(eq(computedKeys.tier, tier))
  if (since) conditions.push(gte(computedKeys.computedAt, since))

  const rows = await db
    .select()
    .from(computedKeys)
    .where(and(...conditions))
    .orderBy(desc(computedKeys.computedAt), desc(computedKeys.level))
    .limit(1000)

  return c.json({ data: rows })
})

// GET /api/market-candles — public read
app.get('/api/market-candles', async (c) => {
  const symbol    = c.req.query('symbol')
  const timeframe = parseInt(c.req.query('timeframe') || '15', 10)
  const limitRaw  = parseInt(c.req.query('limit')     || '200', 10)
  const before    = c.req.query('before')

  if (!symbol) return c.json({ error: 'symbol is required' }, 400)

  const limit = Math.min(Math.max(1, limitRaw), 500)
  const db = getDb(c.env)

  const conditions = [
    eq(marketCandles.symbol,    symbol),
    eq(marketCandles.timeframe, timeframe),
    ...(before ? [lt(marketCandles.openTime, before)] : []),
  ]

  const rows = await db
    .select()
    .from(marketCandles)
    .where(and(...conditions))
    .orderBy(desc(marketCandles.openTime))
    .limit(limit)

  return c.json({ data: rows })
})

// GET /api/sheet-keys?date=YYYY-MM-DD[&tier=h1]
app.get('/api/sheet-keys', async (c) => {
  const date = c.req.query('date')
  const tier = c.req.query('tier')
  if (!date) return c.json({ error: 'date required (YYYY-MM-DD)' }, 400)

  const db = getDb(c.env)
  const conditions = [eq(sheetKeysSnapshot.snapshotDate, date)]
  if (tier) conditions.push(eq(sheetKeysSnapshot.tier, tier))

  const rows = await db
    .select()
    .from(sheetKeysSnapshot)
    .where(and(...conditions))
    .orderBy(sheetKeysSnapshot.tier, sheetKeysSnapshot.level)

  return c.json({ data: rows })
})

// GET /api/sheet-keys/dates — list available snapshot dates
app.get('/api/sheet-keys/dates', async (c) => {
  const db = getDb(c.env)
  const rows = await db
    .selectDistinct({ snapshotDate: sheetKeysSnapshot.snapshotDate })
    .from(sheetKeysSnapshot)
    .orderBy(desc(sheetKeysSnapshot.snapshotDate))
    .limit(90)
  return c.json({ dates: rows.map(r => r.snapshotDate) })
})

async function snapshotSheetKeys(env: Env): Promise<void> {
  const res = await fetch(`${SHEETS_CSV_URL}&_t=${Date.now()}`, {
    redirect: 'follow',
    // @ts-expect-error — Cloudflare Workers fetch extension
    cf: { cacheTtl: 0, cacheEverything: false },
  })
  if (!res.ok) throw new Error(`Sheet fetch failed: ${res.status}`)
  const text = await res.text()
  const lines = text.split('\n').filter(l => l.trim())

  const tierMap: Record<string, number[]> = {
    intraday: [], h1: [], h4: [], daily: [], week: [],
  }
  const tierCols: [string, number][] = [
    ['intraday', 12], ['h1', 14], ['h4', 15], ['daily', 16], ['week', 17],
  ]
  for (let i = 1; i < lines.length; i++) {
    const cols = parseCSVLine(lines[i])
    for (const [tier, idx] of tierCols) {
      const v = parseFloat(cols[idx])
      if (!isNaN(v)) tierMap[tier].push(v)
    }
  }

  // Vietnam date: UTC+7
  const now = new Date()
  const vnDate = new Date(now.getTime() + 7 * 60 * 60 * 1000)
  const snapshotDate = vnDate.toISOString().slice(0, 10)

  const db = getDb(env)
  const rows: { snapshotDate: string; tier: string; level: number }[] = []
  for (const [tier, levels] of Object.entries(tierMap)) {
    for (const level of levels) {
      rows.push({ snapshotDate, tier, level })
    }
  }

  if (rows.length === 0) return
  const CHUNK = 8
  for (let i = 0; i < rows.length; i += CHUNK) {
    await db.insert(sheetKeysSnapshot).values(rows.slice(i, i + CHUNK)).onConflictDoNothing()
  }
  console.log(`[sheet-keys] snapshot ${snapshotDate}: ${rows.length} rows`)
}

// POST /api/sheet-keys/snapshot — manual trigger (requires X-EA-Secret)
app.post('/api/sheet-keys/snapshot', async (c) => {
  const secret = c.req.header('X-EA-Secret')
  if (!secret || secret !== c.env.EA_SECRET) {
    return c.json({ error: 'Unauthorized' }, 401)
  }
  await snapshotSheetKeys(c.env)
  return c.json({ ok: true })
})

const DISCORD_CHANNEL_ID = '1211986974177497159'

async function extractLevelsFromImage(imageBase64: string, ai: Ai): Promise<number[]> {
  const prompt = 'Extract all price numbers shown with a red background highlight in this chart image. Return ONLY a JSON array of numbers, no other text. Example: [4527.81, 4495.62]'
  const res: any = await ai.run('@cf/meta/llama-3.2-11b-vision-instruct', {
    prompt,
    image: [...atob(imageBase64)].map(c => c.charCodeAt(0)),
  })
  const text = (res?.response || res?.result || '').trim()
  const match = text.match(/\[[\d.,\s]+\]/)
  if (!match) throw new Error(`No array in CF AI response: ${text}`)
  return JSON.parse(match[0])
}

async function fetchDiscordIntradayLevels(env: Env): Promise<{ skipped?: boolean; count?: number; msgId?: string }> {
  const res = await fetch(
    `https://discord.com/api/v9/channels/${DISCORD_CHANNEL_ID}/messages?limit=20`,
    { headers: { Authorization: env.DISCORD_TOKEN } }
  )
  if (!res.ok) throw new Error(`Discord API ${res.status}`)
  const msgs: any[] = await res.json()

  const msg = msgs.find(m =>
    m.content?.toLowerCase().includes('intraday levels') &&
    m.attachments?.length > 0
  )
  if (!msg) return { skipped: true }

  const db = getDb(env)
  const existing = await db
    .select({ id: discordIntradayLevels.id })
    .from(discordIntradayLevels)
    .where(eq(discordIntradayLevels.msgId, msg.id))
    .limit(1)
  if (existing.length > 0) return { skipped: true }

  const imgUrl = msg.attachments[0].url
  const imgRes = await fetch(imgUrl)
  if (!imgRes.ok) throw new Error(`Image fetch ${imgRes.status}`)
  const imgBuf = await imgRes.arrayBuffer()
  const imgBase64 = btoa(String.fromCharCode(...new Uint8Array(imgBuf)))

  const levels = await extractLevelsFromImage(imgBase64, env.AI)
  const sourceDate = msg.timestamp.slice(0, 10)

  await db.insert(discordIntradayLevels).values({
    msgId: msg.id,
    sourceDate,
    levels: JSON.stringify(levels.sort((a, b) => b - a)),
  }).onConflictDoNothing()

  console.log(`[discord-intraday] fetched ${levels.length} levels from ${sourceDate}`)
  return { count: levels.length, msgId: msg.id }
}

// GET /api/intraday-discord — latest intraday levels from Discord
app.get('/api/intraday-discord', async (c) => {
  const db = getDb(c.env)
  const rows = await db
    .select()
    .from(discordIntradayLevels)
    .orderBy(desc(discordIntradayLevels.sourceDate))
    .limit(1)
  if (rows.length === 0) return c.json({ levels: [], sourceDate: null })
  const row = rows[0]
  return c.json({ levels: JSON.parse(row.levels), sourceDate: row.sourceDate, msgId: row.msgId })
})

// POST /api/intraday-discord/sync — manual trigger (requires X-EA-Secret)
app.post('/api/intraday-discord/sync', async (c) => {
  const secret = c.req.header('X-EA-Secret')
  if (!secret || secret !== c.env.EA_SECRET) {
    return c.json({ error: 'Unauthorized' }, 401)
  }
  const result = await fetchDiscordIntradayLevels(c.env)
  return c.json({ ok: true, ...result })
})

export default {
  fetch: app.fetch,
  async scheduled(event: ScheduledEvent, env: Env, _ctx: ExecutionContext) {
    if (event.cron === '30 21 * * *') {
      await fetchDiscordIntradayLevels(env)
    } else {
      await snapshotSheetKeys(env)
    }
  },
}
