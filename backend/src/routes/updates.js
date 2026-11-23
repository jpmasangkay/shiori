import express from 'express';
import { LibraryEntry } from '../models.js';
import { optionalAuth } from '../middleware/auth.js';
import { getLatestChapters } from '../services/mangadex.js';

const router = express.Router();
const MANGADEX_UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

router.use(optionalAuth);

// GET /api/updates - Latest chapter releases (rate-limited batches for MangaDex entries)
router.get('/', async (req, res) => {
  try {
    let mangaList = [];

    if (req.user && req.user.id) {
      const libraryEntries = await LibraryEntry.find({ user: req.user.id })
        .sort({ updatedAt: -1 })
        .limit(40)
        .lean();

      mangaList = libraryEntries
        .filter((e) => {
          const clean = String(e.mangaId || '').replace(/^mangadex:/i, '');
          return MANGADEX_UUID_RE.test(clean);
        })
        .map((e) => ({
          id: String(e.mangaId).replace(/^mangadex:/i, ''),
          originalId: e.mangaId,
          title: e.title,
          cover: e.cover,
        }));
    }

    if (mangaList.length === 0) {
      return res.json({
        groups: { Today: [], Yesterday: [], Earlier: [] },
        items: [],
        total: 0,
      });
    }

    // Batch 4 concurrent requests with 220ms spacing to stay cleanly under MangaDex 5 req/s
    const allResults = [];
    const batchSize = 4;
    for (let i = 0; i < mangaList.length; i += batchSize) {
      if (i > 0) {
        await new Promise((r) => setTimeout(r, 220));
      }
      const batch = mangaList.slice(i, i + batchSize);
      const batchResults = await Promise.all(
        batch.map(async (manga) => {
          try {
            const chapters = await getLatestChapters(manga.id, { lang: 'en', limit: 2 });
            return chapters.map((ch) => ({
              id: ch.id,
              mangaId: manga.originalId,
              mangaTitle: manga.title,
              cover: manga.cover,
              chapterNumber: ch.number,
              chapterTitle: ch.title,
              group: ch.group || 'MangaDex',
              publishAt: ch.publishAt,
              pages: ch.pages,
            }));
          } catch {
            return [];
          }
        }),
      );
      allResults.push(...batchResults);
    }

    const flattened = allResults
      .flat()
      .filter(Boolean)
      .sort((a, b) => new Date(b.publishAt || 0) - new Date(a.publishAt || 0));

    const now = new Date();
    const todayStr = now.toISOString().slice(0, 10);
    const yesterdayStr = new Date(now.getTime() - 24 * 60 * 60 * 1000).toISOString().slice(0, 10);

    const groups = { Today: [], Yesterday: [], Earlier: [] };
    for (const item of flattened) {
      const d = item.publishAt ? new Date(item.publishAt).toISOString().slice(0, 10) : '';
      if (d === todayStr) groups.Today.push(item);
      else if (d === yesterdayStr) groups.Yesterday.push(item);
      else groups.Earlier.push(item);
    }

    return res.json({
      groups,
      items: flattened,
      total: flattened.length,
    });
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
});

export default router;
