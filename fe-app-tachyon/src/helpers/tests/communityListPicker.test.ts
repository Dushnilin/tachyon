import { describe, expect, it } from 'vitest';

import {
  COMMUNITY_LIST_SUPERSETS,
  getSubsumedCommunityLists,
} from '../communityListPicker';

describe('getSubsumedCommunityLists', () => {
  it('returns empty map when no superset lists are selected', () => {
    const result = getSubsumedCommunityLists(['youtube', 'discord', 'openai']);
    expect(result.size).toBe(0);
  });

  it('marks 100% included child lists when russia_inside is selected', () => {
    const result = getSubsumedCommunityLists(['russia_inside']);
    expect(result.get('geoblock')).toEqual(['russia_inside']);
    expect(result.get('block')).toEqual(['russia_inside']);
    expect(result.get('xai')).toEqual(['russia_inside']);
    expect(result.get('hdrezka')).toEqual(['russia_inside']);
    expect(result.get('anime')).toEqual(['russia_inside']);
    expect(result.get('news')).toEqual(['russia_inside']);
    // Lists with extra IP subnets or independent domains must NOT be subsumed
    expect(result.has('ru_blocked')).toBe(false);
    expect(result.has('refilter')).toBe(false);
    expect(result.has('antifilter')).toBe(false);
    expect(result.has('youtube')).toBe(false);
  });

  it('marks openai, anthropic, and xai as subsumed when ai_all is selected, but not google_ai', () => {
    const result = getSubsumedCommunityLists(['ai_all']);
    expect(result.get('openai')).toEqual(['ai_all']);
    expect(result.get('anthropic')).toEqual(['ai_all']);
    expect(result.get('xai')).toEqual(['ai_all']);
    expect(result.has('google_ai')).toBe(false);
  });

  it('accumulates multiple covering parent lists when both russia_inside and ai_all are selected', () => {
    const result = getSubsumedCommunityLists(['russia_inside', 'ai_all']);
    expect(result.get('xai')).toEqual(['russia_inside', 'ai_all']);
  });

  it('marks ru_only_inside and geosite_ru when ru_domains is selected', () => {
    const result = getSubsumedCommunityLists(['ru_domains']);
    expect(result.get('geosite_ru')).toEqual(['ru_domains']);
    expect(result.get('ru_only_inside')).toEqual(['ru_domains']);
    expect(COMMUNITY_LIST_SUPERSETS.twitch).toEqual(['twitch_ads']);
    expect(COMMUNITY_LIST_SUPERSETS.ru_blocked_all).toEqual(['antifilter']);
  });
});
