import express from 'express';
import { Progress } from '../models.js';
import { requireAuth } from '../middleware/auth.js';

const router = express.Router();

router.use(requireAuth);

// POST /api/progress - Save or update reading progress
router.post('/', async (req, res) => {
  try {
    const {
      mangaId,
      chapterId,
      mangaTitle,
      cover,
      source,
      chapterNumber,
      chapterTitle,
      page,
      totalPages,
      completed,
      updatedAt,
    } = req.body;

    if (typeof mangaId !== 'string' || typeof chapterId !== 'string' || !mangaId.trim() || !chapterId.trim()) {
      return res.status(400).json({ error: 'Valid mangaId and chapterId are required' });
    }

    const cleanMangaId = mangaId.trim();
    const cleanChapterId = chapterId.trim();
    const parsedUpdatedAt = updatedAt ? new Date(updatedAt) : null;
    const validUpdatedAt =
      parsedUpdatedAt && !Number.isNaN(parsedUpdatedAt.getTime()) ? parsedUpdatedAt : null;

    const doc = await Progress.findOneAndUpdate(
      { user: req.user.id, chapterId: cleanChapterId },
      {
        $set: {
          mangaId: cleanMangaId,
          mangaTitle: typeof mangaTitle === 'string' ? mangaTitle.trim().slice(0, 200) : '',
          cover: typeof cover === 'string' ? cover.trim() : '',
          source: typeof source === 'string' ? source.trim().slice(0, 80) : '',
          chapterNumber: typeof chapterNumber === 'string' ? chapterNumber.trim() : String(chapterNumber || ''),
          chapterTitle: typeof chapterTitle === 'string' ? chapterTitle.trim().slice(0, 200) : '',
          page: Math.max(1, Number(page) || 1),
          totalPages: Math.max(0, Number(totalPages) || 0),
          completed: Boolean(completed),
          ...(validUpdatedAt ? { updatedAt: validUpdatedAt } : {}),
        },
      },
      { upsert: true, new: true, setDefaultsOnInsert: true, timestamps: !validUpdatedAt },
    );

    res.json(doc);
  } catch (err) {
    console.error('[Progress Save Error]', err.message);
    res.status(500).json({ error: 'Failed to update reading progress' });
  }
});

// POST /api/progress/batch - Batch upload reading progress, history, and completed chapters
router.post('/batch', async (req, res) => {
  try {
    const rawEntries = Array.isArray(req.body?.entries) ? req.body.entries : [];
    const readChaptersByManga =
      req.body?.readChaptersByManga && typeof req.body.readChaptersByManga === 'object'
        ? req.body.readChaptersByManga
        : {};

    const existingDocs = await Progress.find({ user: req.user.id }).select(
      'chapterId updatedAt completed page',
    );
    const existingByChapter = new Map(existingDocs.map((d) => [d.chapterId, d]));

    const ops = [];
    for (const item of rawEntries.slice(0, 1000)) {
      if (!item || typeof item.mangaId !== 'string' || typeof item.chapterId !== 'string') continue;
      const cleanMangaId = item.mangaId.trim();
      const cleanChapterId = item.chapterId.trim();
      if (!cleanMangaId || !cleanChapterId) continue;

      const parsedDate = item.updatedAt ? new Date(item.updatedAt) : null;
      const clientDate =
        parsedDate && !Number.isNaN(parsedDate.getTime()) ? parsedDate : new Date();

      const existing = existingByChapter.get(cleanChapterId);
      if (existing && existing.updatedAt && existing.updatedAt > clientDate) {
        // Server already has a newer record; still preserve completed=true if client marked completed.
        if (item.completed && !existing.completed) {
          ops.push({
            updateOne: {
              filter: { user: req.user.id, chapterId: cleanChapterId },
              update: { $set: { completed: true } },
            },
          });
        }
        continue;
      }

      ops.push({
        updateOne: {
          filter: { user: req.user.id, chapterId: cleanChapterId },
          update: {
            $set: {
              mangaId: cleanMangaId,
              mangaTitle:
                typeof item.mangaTitle === 'string' ? item.mangaTitle.trim().slice(0, 200) : '',
              cover: typeof item.cover === 'string' ? item.cover.trim() : '',
              source: typeof item.source === 'string' ? item.source.trim().slice(0, 80) : '',
              chapterNumber:
                typeof item.chapterNumber === 'string'
                  ? item.chapterNumber.trim()
                  : String(item.chapterNumber || ''),
              chapterTitle:
                typeof item.chapterTitle === 'string' ? item.chapterTitle.trim().slice(0, 200) : '',
              page: Math.max(1, Number(item.page) || 1),
              totalPages: Math.max(0, Number(item.totalPages) || 0),
              completed: Boolean(item.completed),
              updatedAt: clientDate,
            },
            $setOnInsert: { createdAt: clientDate },
          },
          upsert: true,
          timestamps: false,
        },
      });
    }

    // Also sync read-chapter sets (unread badges) that might not have full progress rows yet
    for (const [mangaId, chapterList] of Object.entries(readChaptersByManga).slice(0, 500)) {
      const cleanMangaId = String(mangaId).trim();
      if (!cleanMangaId || !Array.isArray(chapterList)) continue;
      for (const chId of chapterList.slice(0, 2000)) {
        if (typeof chId !== 'string' || !chId.trim()) continue;
        const cleanChapterId = chId.trim();
        const existing = existingByChapter.get(cleanChapterId);
        if (existing?.completed) continue;
        ops.push({
          updateOne: {
            filter: { user: req.user.id, chapterId: cleanChapterId },
            update: {
              $set: { mangaId: cleanMangaId, completed: true },
              $setOnInsert: { page: 1, totalPages: 0 },
            },
            upsert: true,
          },
        });
      }
    }

    if (ops.length > 0) {
      await Progress.bulkWrite(ops);
    }

    res.json({ success: true, updated: ops.length });
  } catch (err) {
    console.error('[Progress Batch Error]', err.message);
    res.status(500).json({ error: 'Failed to batch sync reading progress' });
  }
});

// GET /api/progress/sync - Full cross-device state (history, latest progress per manga, read chapters)
router.get('/sync', async (req, res) => {
  try {
    const records = await Progress.find({ user: req.user.id }).sort({ updatedAt: -1 }).limit(5000);
    const history = [];
    const seenHistoryManga = new Set();
    const progressByManga = {};
    const readChaptersByManga = {};

    for (const r of records) {
      if (r.completed) {
        if (!readChaptersByManga[r.mangaId]) {
          readChaptersByManga[r.mangaId] = [];
        }
        readChaptersByManga[r.mangaId].push(r.chapterId);
      }

      if (!progressByManga[r.mangaId]) {
        progressByManga[r.mangaId] = {
          mangaId: r.mangaId,
          chapterId: r.chapterId,
          mangaTitle: r.mangaTitle,
          cover: r.cover,
          source: r.source,
          chapterNumber: r.chapterNumber,
          chapterTitle: r.chapterTitle,
          page: r.page,
          totalPages: r.totalPages,
          completed: r.completed,
          updatedAt: r.updatedAt,
        };
      }

      if (r.mangaTitle && !seenHistoryManga.has(r.mangaId) && history.length < 200) {
        seenHistoryManga.add(r.mangaId);
        history.push(r);
      }
    }

    res.json({
      history,
      progressByManga,
      readChaptersByManga,
    });
  } catch (err) {
    console.error('[Progress Sync Error]', err.message);
    res.status(500).json({ error: 'Failed to retrieve sync state' });
  }
});

// GET /api/progress/manga/:mangaId - All chapter progress for a given manga
router.get('/manga/:mangaId', async (req, res) => {
  try {
    const records = await Progress.find({
      user: req.user.id,
      mangaId: req.params.mangaId,
    }).sort({ updatedAt: -1 });

    const lastRead = records[0] || null;
    const completedChapterIds = records
      .filter((r) => r.completed)
      .map((r) => r.chapterId);

    res.json({
      mangaId: req.params.mangaId,
      lastRead,
      completedChapterIds,
      completedChapters: completedChapterIds,
      progressMap: Object.fromEntries(
        records.map((r) => [
          r.chapterId,
          {
            page: r.page,
            totalPages: r.totalPages,
            completed: r.completed,
            updatedAt: r.updatedAt,
          },
        ]),
      ),
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// GET /api/progress/history - Recently read items
router.get('/history', async (req, res) => {
  try {
    const limit = Math.min(Number(req.query.limit) || 100, 300);
    const history = await Progress.find({ user: req.user.id })
      .sort({ updatedAt: -1 })
      .limit(limit);

    res.json({ items: history, total: history.length });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// DELETE /api/progress/history - Clear all history/progress for current user
router.delete('/history', async (req, res) => {
  try {
    const result = await Progress.deleteMany({ user: req.user.id });
    res.json({ success: true, deletedCount: result.deletedCount || 0 });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// DELETE /api/progress/manga/:mangaId - Remove history entries for a specific manga
router.delete('/manga/:mangaId', async (req, res) => {
  try {
    await Progress.deleteMany({
      user: req.user.id,
      mangaId: req.params.mangaId,
    });
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// DELETE /api/progress/history/:chapterId - Remove specific history entry
router.delete('/history/:chapterId', async (req, res) => {
  try {
    await Progress.findOneAndDelete({
      user: req.user.id,
      chapterId: req.params.chapterId,
    });
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

export default router;
