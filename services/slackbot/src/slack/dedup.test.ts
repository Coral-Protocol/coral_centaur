import { describe, expect, it } from 'bun:test'
import { EventDeduper, slackDedupKey } from './dedup'

describe('EventDeduper', () => {
  it('rejects duplicate keys until the TTL expires', () => {
    const deduper = new EventDeduper(100)

    expect(deduper.checkAndRemember('event:Ev123', 1_000)).toBe(true)
    expect(deduper.checkAndRemember('event:Ev123', 1_050)).toBe(false)
    expect(deduper.checkAndRemember('event:Ev123', 1_101)).toBe(true)
  })

  it('prefers Slack event IDs and falls back to message identity', () => {
    expect(
      slackDedupKey({
        eventId: 'Ev123',
        teamId: 'T123',
        channelId: 'C123',
        messageTs: '1778883099.579529'
      })
    ).toBe('event:Ev123')

    expect(
      slackDedupKey({
        teamId: 'T123',
        channelId: 'C123',
        messageTs: '1778883099.579529'
      })
    ).toBe('message:T123:C123:1778883099.579529')
  })
})
