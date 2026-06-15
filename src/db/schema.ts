import { sqliteTable, integer, real, text } from 'drizzle-orm/sqlite-core'
import { sql } from 'drizzle-orm'

export const marketCandles = sqliteTable('market_candles', {
  id:           integer('id').primaryKey({ autoIncrement: true }),
  symbol:       text('symbol').notNull(),
  timeframe:    integer('timeframe').notNull().default(15),
  openTime:     text('open_time').notNull(),
  open:         real('open').notNull(),
  high:         real('high').notNull(),
  low:          real('low').notNull(),
  close:        real('close').notNull(),
  tickVolume:   integer('tick_volume').notNull().default(0),
  maFast:       real('ma_fast'),
  maMid:        real('ma_mid'),
  maSlow:       real('ma_slow'),
  maFastPeriod: integer('ma_fast_period'),
  maMidPeriod:  integer('ma_mid_period'),
  maSlowPeriod: integer('ma_slow_period'),
  maFour:       real('ma_four'),
  maFive:       real('ma_five'),
  maFourPeriod: integer('ma_four_period'),
  maFivePeriod: integer('ma_five_period'),
  rsi:          real('rsi'),
  rsiPeriod:    integer('rsi_period'),
  pivot:        real('pivot'),
  r1:           real('r1'),
  r2:           real('r2'),
  r3:           real('r3'),
  s1:           real('s1'),
  s2:           real('s2'),
  s3:           real('s3'),
  dayOpen:      real('day_open'),
  fibHigh:      real('fib_high'),
  fibLow:       real('fib_low'),
  fib0:         real('fib_0'),
  fib236:       real('fib_236'),
  fib382:       real('fib_382'),
  fib500:       real('fib_500'),
  fib618:       real('fib_618'),
  fib786:       real('fib_786'),
  fib100:       real('fib_100'),
  createdAt:    text('created_at').notNull().default(sql`(datetime('now'))`),
})

export const sheetKeysSnapshot = sqliteTable('sheet_keys_snapshot', {
  id:           integer('id').primaryKey({ autoIncrement: true }),
  snapshotDate: text('snapshot_date').notNull(),
  tier:         text('tier').notNull(),
  level:        real('level').notNull(),
  createdAt:    text('created_at').notNull().default(sql`(datetime('now'))`),
})

export const discordIntradayLevels = sqliteTable('discord_intraday_levels', {
  id:         integer('id').primaryKey({ autoIncrement: true }),
  msgId:      text('msg_id').notNull().unique(),
  sourceDate: text('source_date').notNull(),
  levels:     text('levels').notNull(),
  fetchedAt:  text('fetched_at').notNull().default(sql`(datetime('now'))`),
})

export const computedKeys = sqliteTable('computed_keys', {
  id:           integer('id').primaryKey({ autoIncrement: true }),
  symbol:       text('symbol').notNull(),
  tier:         text('tier').notNull(),
  level:        real('level').notNull(),
  side:         text('side').notNull(),
  sourceCount:  integer('source_count').notNull(),
  tierMask:     integer('tier_mask'),
  confluence:   integer('confluence'),
  bidRef:       real('bid_ref').notNull(),
  computedAt:   text('computed_at').notNull(),
  createdAt:    text('created_at').notNull().default(sql`(datetime('now'))`),
})
