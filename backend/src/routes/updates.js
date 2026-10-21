import express from 'express';
import { LibraryEntry } from '../models.js';
import { optionalAuth } from '../middleware/auth.js';
import { getLatestChapters, mdRequest, normalizeChapter, normalizeManga } from '../services/mangadex.js';

const router = express.Router();

router.use(optionalAuth);

// GET /api/updates - Latest chapter releases
router.get('/', async (req, res) => {
  try {
    let mangaList = [];

    // If user is authenticated, check their library
    if (req.user && req.user.id) {
      const libraryEntries = await LibraryEntry.find({ user: req.user.id })
        .sort({ updatedAt: -1 })
        .limit(15);

      if (libraryEntries.length > 0) {
        mangaList = libraryEntries.map((e) => ({
          id: e.mangaId,
          title: e.title,
          cover: e.cover,
        }));
      }
    }

    // If library is empty or user is unauthenticated, return empty updates
    // Updates must ONLY show new chapters for series bookmarked in library
    if (mangaList.length === 0) {
      return res.json({
        groups: {
          Today: [],
          Yesterday: [],
          Earlier: [],
        },
        items: [],
        total: 0,
      });
    }

    // Fetch the 1-2 latest chapters for each manga in parallel
    const chapterPromises = mangaList.map(async (manga) => {
      try {
        const chapters = await getLatestChapters(manga.id, { lang: 'en', limit: 2 });
        return chapters.map((ch) => ({
          id: ch.id,
          mangaId: manga.id,
          mangaTitle: manga.title,
          cover: manga.cover,
          chapterNumber: ch.number,
          chapterTitle: ch.title,
          group: ch.group || 'MangaDex',
          publishAt: ch.publishAt,
          pages: ch.pages,
        }));
      } catch (err) {
        return [];
      }
    });

    const results = await Promise.all(chapterPromises);
    const flattened = results
      .flat()
      .filter(Boolean)
      .sort((a, b) => new Date(b.publishAt || 0) - new Date(a.publishAt || 0));

    // Group chapters by human-friendly date buckets
    const now = new Date();
    const todayStr = now.toISOString().slice(0, 10);
    const yesterday = new Date(now.getTime() - 24 * 60 * 60 * 1000);
    const yesterdayStr = yesterday.toISOString().slice(0, 10);

    const groups = {
      Today: [],
      Yesterday: [],
      Earlier: [],
    };

    for (const item of flattened) {
      const d = item.publishAt ? new Date(item.publishAt).toISOString().slice(0, 10) : '';
      if (d === todayStr) {
        groups.Today.push(item);
      } else if (d === yesterdayStr) {
        groups.Yesterday.push(item);
      } else {
        groups.Earlier.push(item);
      }
    }

    res.json({
      groups,
      items: flattened,
      total: flattened.length,
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

export default router;
