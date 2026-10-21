/**
 * Thin client for the free MangaDex API (https://api.mangadex.org/docs/).
 *
 * - Throttled to stay under MangaDex's ~5 requests/second/IP limit.
 * - Small in-memory TTL cache so repeated browsing doesn't burn the quota.
 * - Normalises MangaDex's verbose JSON:API responses to flat objects the
 *   Flutter app can consume directly.
 */

const BASE = 'https://api.mangadex.org';
const COVERS = 'https://uploads.mangadex.org/covers';
const USER_AGENT = 'ShioriApp/1.0 (personal manga reader)';
const MIN_GAP_MS = 230;
const CONTENT_RATINGS = ['safe', 'suggestive'];

export class UpstreamError extends Error {
  constructor(message, status = 502) {
    super(message);
    this.status = status;
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- throttling --------------------------------------------------------
let chain = Promise.resolve();
let lastStart = 0;
function waitForSlot() {
  const slot = chain.then(async () => {
    const wait = Math.max(0, lastStart + MIN_GAP_MS - Date.now());
    if (wait) await sleep(wait);
    lastStart = Date.now();
  });
  chain = slot.catch(() => {});
  return slot;
}

// ---- cache -------------------------------------------------------------
const cache = new Map();
const CACHE_MAX = 600;
function cacheGet(key) {
  const hit = cache.get(key);
  if (!hit) return undefined;
  if (hit.exp < Date.now()) {
    cache.delete(key);
    return undefined;
  }
  return hit.val;
}
function cacheSet(key, val, ttlMs) {
  if (cache.size >= CACHE_MAX) cache.delete(cache.keys().next().value);
  cache.set(key, { val, exp: Date.now() + ttlMs });
}
export function clearCache() {
  cache.clear();
}

// ---- http --------------------------------------------------------------
function buildUrl(path, params) {
  const url = new URL(BASE + path);
  for (const [key, value] of Object.entries(params)) {
    if (value === undefined || value === null || value === '') continue;
    if (Array.isArray(value)) value.forEach((v) => url.searchParams.append(`${key}[]`, v));
    else url.searchParams.append(key, String(value));
  }
  return url;
}

export async function mdRequest(path, params = {}, { ttl = 0, fetchImpl = fetch } = {}) {
  const url = buildUrl(path, params);
  const key = url.toString();
  if (ttl) {
    const hit = cacheGet(key);
    if (hit !== undefined) return hit;
  }

  for (let attempt = 0; attempt < 2; attempt++) {
    await waitForSlot();
    let res;
    try {
      res = await fetchImpl(url, {
        headers: { 'User-Agent': USER_AGENT, Accept: 'application/json' },
        signal: AbortSignal.timeout(15000),
      });
    } catch (err) {
      throw new UpstreamError(`MangaDex unreachable: ${err.message}`, 502);
    }
    if (res.status === 429 && attempt === 0) {
      const retry = Number(res.headers.get('retry-after')) || 1;
      await sleep(Math.min(retry, 5) * 1000);
      continue;
    }
    if (res.status === 404) throw new UpstreamError('Not found', 404);
    if (res.status === 429) throw new UpstreamError('MangaDex rate limit hit, try again shortly', 503);
    if (!res.ok) throw new UpstreamError(`MangaDex responded ${res.status}`, 502);
    const json = await res.json();
    if (ttl) cacheSet(key, json, ttl);
    return json;
  }
  throw new UpstreamError('MangaDex request failed', 502);
}

// ---- normalisers -------------------------------------------------------
const pickLocalized = (map) => {
  if (!map || typeof map !== 'object') return '';
  return map.en || Object.values(map)[0] || '';
};

export function languageToType(lang) {
  if (lang === 'ko') return 'manhwa';
  if (lang && lang.startsWith('zh')) return 'manhua';
  return 'manga';
}

export function typeToLanguages(type) {
  switch (type) {
    case 'manga':
      return ['ja'];
    case 'manhwa':
      return ['ko'];
    case 'manhua':
      return ['zh', 'zh-hk'];
    default:
      return undefined;
  }
}

export function normalizeManga(m) {
  const a = m.attributes || {};
  const rels = m.relationships || [];
  const coverRel = rels.find((r) => r.type === 'cover_art');
  const fileName = coverRel?.attributes?.fileName;

  let title = a.title?.en;
  if (!title) title = (a.altTitles || []).map((t) => t.en).find(Boolean);
  if (!title) title = pickLocalized(a.title);

  const authors = [
    ...new Set(
      rels
        .filter((r) => r.type === 'author' || r.type === 'artist')
        .map((r) => r.attributes?.name)
        .filter(Boolean),
    ),
  ];

  return {
    id: m.id,
    title,
    description: pickLocalized(a.description),
    authors,
    status: a.status || '',
    type: languageToType(a.originalLanguage),
    tags: (a.tags || []).map((t) => t.attributes?.name?.en).filter(Boolean),
    cover: fileName ? `${COVERS}/${m.id}/${fileName}.512.jpg` : '',
    year: a.year || null,
    contentRating: a.contentRating || '',
    lastChapter: a.lastChapter || '',
  };
}

export function normalizeChapter(c) {
  const a = c.attributes || {};
  const group = (c.relationships || []).find((r) => r.type === 'scanlation_group');
  return {
    id: c.id,
    number: a.chapter ?? null,
    volume: a.volume ?? null,
    title: a.title || '',
    pages: a.pages || 0,
    language: a.translatedLanguage || '',
    publishAt: a.publishAt || a.readableAt || a.createdAt,
    group: group?.attributes?.name || '',
  };
}

const chapterSortValue = (c) => {
  const n = parseFloat(c.number);
  return Number.isNaN(n) ? -1 : n;
};

/** Several scanlation groups often upload the same chapter; keep the fullest one. */
export function dedupeChapters(chapters) {
  const byNumber = new Map();
  const result = [];
  for (const c of chapters) {
    if (c.number === null) {
      result.push(c);
      continue;
    }
    const key = `${c.volume ?? ''}|${c.number}`;
    const existing = byNumber.get(key);
    if (!existing || c.pages > existing.pages) byNumber.set(key, c);
  }
  result.push(...byNumber.values());
  return result.sort((x, y) => chapterSortValue(y) - chapterSortValue(x));
}

// ---- public api --------------------------------------------------------
const MIN = 60 * 1000;

export async function searchManga({ q, type, order = 'popular', page = 1, limit = 24, tag, lang }) {
  const lim = Math.min(Math.max(Number(limit) || 24, 1), 50);
  const pg = Math.max(Number(page) || 1, 1);
  const sort = {
    popular: { 'order[followedCount]': 'desc' },
    latest: { 'order[latestUploadedChapter]': 'desc' },
    rating: { 'order[rating]': 'desc' },
    new: { 'order[createdAt]': 'desc' },
    relevance: { 'order[relevance]': 'desc' },
  };
  const orderParams = q && order === 'popular' ? sort.relevance : sort[order] || sort.popular;

  const json = await mdRequest(
    '/manga',
    {
      title: q,
      limit: lim,
      offset: (pg - 1) * lim,
      originalLanguage: typeToLanguages(type),
      availableTranslatedLanguage: lang && lang.toLowerCase() !== 'all' ? [lang.toLowerCase()] : ['en'],
      hasAvailableChapters: 'true',
      contentRating: CONTENT_RATINGS,
      includes: ['cover_art', 'author', 'artist'],
      includedTags: tag ? [tag] : undefined,
      ...orderParams,
    },
    { ttl: 5 * MIN },
  );
  return {
    items: json.data.map(normalizeManga),
    total: json.total ?? json.data.length,
    page: pg,
    limit: lim,
  };
}

export async function getManga(id) {
  const json = await mdRequest(
    `/manga/${id}`,
    { includes: ['cover_art', 'author', 'artist'] },
    { ttl: 30 * MIN },
  );
  return normalizeManga(json.data);
}

const FEED_PAGE = 500;
const FEED_CAP = 3000;

export async function getChapters(mangaId, { lang = 'en' } = {}) {
  const fetchForLang = async (targetLang) => {
    const all = [];
    let offset = 0;
    let total = Infinity;
    while (offset < total && offset < FEED_CAP) {
      const params = {
        limit: FEED_PAGE,
        offset,
        includeExternalUrl: 0,
        contentRating: [...CONTENT_RATINGS, 'erotica'],
        includes: ['scanlation_group'],
        'order[chapter]': 'desc',
      };
      if (targetLang) {
        params.translatedLanguage = [targetLang];
      }
      const json = await mdRequest(`/manga/${mangaId}/feed`, params, { ttl: 5 * MIN });
      all.push(...json.data.map(normalizeChapter));
      total = json.total ?? all.length;
      offset += FEED_PAGE;
      if (!json.data.length) break;
    }
    return all;
  };

  let list = await fetchForLang(lang);
  if (!list.length && lang) {
    list = await fetchForLang(null);
  }
  return dedupeChapters(list);
}


/** Latest few chapters of one title, used to build the Updates feed. */
export async function getLatestChapters(mangaId, { lang = 'en', limit = 3 } = {}) {
  const json = await mdRequest(
    `/manga/${mangaId}/feed`,
    {
      translatedLanguage: [lang],
      limit,
      includeExternalUrl: 0,
      contentRating: [...CONTENT_RATINGS, 'erotica'],
      includes: ['scanlation_group'],
      'order[publishAt]': 'desc',
    },
    { ttl: 10 * MIN },
  );
  return json.data.map(normalizeChapter);
}

export async function getChapterPages(chapterId) {
  const json = await mdRequest(`/at-home/server/${chapterId}`, {});
  const { baseUrl, chapter } = json;
  if (!baseUrl || !chapter) throw new UpstreamError('Chapter has no hosted pages', 404);
  return {
    chapterId,
    pages: chapter.data.map((f) => `${baseUrl}/data/${chapter.hash}/${f}`),
    dataSaver: chapter.dataSaver.map((f) => `${baseUrl}/data-saver/${chapter.hash}/${f}`),
  };
}
