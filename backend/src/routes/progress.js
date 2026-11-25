import express from 'express';
import { ChapterBookmark, Progress, User } from '../models.js';
import { requireAuth } from '../middleware/auth.js';

const router = express.Router();

router.use(requireAuth);

function safeDecodeParam(raw) {
  if (typeof raw !== 'string') return '';
  try {
    return decodeURIComponent(raw).trim();
  } catch {
    return raw.trim();
  }
}

async function getUserBookmarks(userId) {
  const [docs, userDoc] = await Promise.all([
    ChapterBookmark.find({ user: userId }).select('chapterId').limit(5000).lean(),
    User.findById(userId).select('chapterBookmarks').lean(),
  ]);
  const merged = new Set(docs.map((d) => d.chapterId));
  const legacy = Array.isArray(userDoc?.chapterBookmarks) ? userDoc.chapterBookmarks : [];
  if (legacy.length > 0) {
    const ops = [];
    for (const id of legacy.slice(0, 5000)) {
      if (typeof id === 'string' && id.trim()) {
        const clean = id.trim();
        merged.add(clean);
        ops.push({
          updateOne: {
            filter: { user: userId, chapterId: clean },
            update: { $setOnInsert: { user: userId, chapterId: clean } },
            upsert: true,
          },
        });
      }
    }
    if (ops.length > 0) {
      await ChapterBookmark.bulkWrite(ops, { ordered: false }).catch(() => {});
      await User.findByIdAndUpdate(userId, { $set: { chapterBookmarks: [] } }).catch(() => {});
    }
  }
  return Array.from(merged);
}

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

    const setFields = {
      mangaId: cleanMangaId,
      mangaTitle: typeof mangaTitle === 'string' ? mangaTitle.trim().slice(0, 200) : '',
      cover: typeof cover === 'string' ? cover.trim() : '',
      source: typeof source === 'string' ? source.trim().slice(0, 80) : '',
      chapterNumber: typeof chapterNumber === 'string' ? chapterNumber.trim() : String(chapterNumber || ''),
      chapterTitle: typeof chapterTitle === 'string' ? chapterTitle.trim().slice(0, 200) : '',
      page: Math.max(1, Number(page) || 1),
      totalPages: Math.max(0, Number(totalPages) || 0),
      ...(validUpdatedAt ? { updatedAt: validUpdatedAt } : {}),
    };
    const updateDoc = completed
      ? { $set: { ...setFields, completed: true } }
      : { $set: setFields, $setOnInsert: { completed: false } };

    const doc = await Progress.findOneAndUpdate(
      { user: req.user.id, chapterId: cleanChapterId },
      updateDoc,
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

    const existingDocs = await Progress.find({ user: req.user.id })
      .select('mangaId chapterId updatedAt completed page')
      .lean();
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
              completed: Boolean(item.completed || existing?.completed),
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
    for (const [mangaId, chapterList] of Object.entries(readChaptersByManga).slice(0, 2000)) {
      const cleanMangaId = String(mangaId).trim();
      if (!cleanMangaId || !Array.isArray(chapterList)) continue;
      for (const chId of chapterList.slice(0, 5000)) {
        if (typeof chId !== 'string' || !chId.trim()) continue;
        const cleanChapterId = chId.trim();
        const existing = existingByChapter.get(cleanChapterId);
        if (existing?.completed && existing?.mangaId === cleanMangaId) continue;
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

    const rawBookmarks = Array.isArray(req.body?.chapterBookmarks) ? req.body.chapterBookmarks : null;
    if (rawBookmarks && rawBookmarks.length > 0) {
      const cleanBookmarks = rawBookmarks
        .filter((id) => typeof id === 'string' && id.trim())
        .map((id) => id.trim())
        .slice(0, 5000);
      if (cleanBookmarks.length > 0) {
        await ChapterBookmark.bulkWrite(
          cleanBookmarks.map((chapterId) => ({
            updateOne: {
              filter: { user: req.user.id, chapterId },
              update: { $setOnInsert: { user: req.user.id, chapterId } },
              upsert: true,
            },
          })),
          { ordered: false },
        );
      }
    }

    res.json({ success: true, updated: ops.length });
  } catch (err) {
    console.error('[Progress Batch Error]', err.message);
    res.status(500).json({ error: 'Failed to batch sync reading progress' });
  }
});

// GET /api/progress/sync - Full cross-device state (history, latest progress per manga, ALL read chapters)
router.get('/sync', async (req, res) => {
  try {
    // Fetch ALL completed chapter IDs via lean projection (no 5,000-chapter truncation!)
    // alongside recent progress/history records and chapter bookmarks in parallel.
    const [completedDocs, recentRecords, chapterBookmarks] = await Promise.all([
      Progress.find({ user: req.user.id, completed: true })
        .select('mangaId chapterId -_id')
        .lean(),
      Progress.find({ user: req.user.id })
        .sort({ updatedAt: -1 })
        .limit(5000)
        .lean(),
      getUserBookmarks(req.user.id),
    ]);

    const readChaptersByManga = {};
    for (const doc of completedDocs) {
      if (!doc.mangaId || !doc.chapterId) continue;
      if (!readChaptersByManga[doc.mangaId]) {
        readChaptersByManga[doc.mangaId] = [];
      }
      readChaptersByManga[doc.mangaId].push(doc.chapterId);
    }

    const history = [];
    const seenHistoryManga = new Set();
    const progressByManga = {};

    for (const r of recentRecords) {
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
      chapterBookmarks,
    });
  } catch (err) {
    console.error('[Progress Sync Error]', err.message);
    res.status(500).json({ error: 'Failed to retrieve sync state' });
  }
});

// POST /api/progress/read-status - Update read/unread status for single or multiple chapters
router.post('/read-status', async (req, res) => {
  try {
    const { mangaId, chapterId, chapterIds, read } = req.body || {};
    const isRead = read !== false;
    const cleanMangaId = typeof mangaId === 'string' ? mangaId.trim() : '';

    const targetIds = [];
    if (typeof chapterId === 'string' && chapterId.trim()) {
      targetIds.push(chapterId.trim());
    }
    if (Array.isArray(chapterIds)) {
      for (const id of chapterIds) {
        if (typeof id === 'string' && id.trim()) {
          targetIds.push(id.trim());
        }
      }
    }

    if (targetIds.length === 0) {
      return res.status(400).json({ error: 'Valid chapterId or chapterIds required' });
    }

    const ops = targetIds.slice(0, 2000).map((chId) => ({
      updateOne: {
        filter: { user: req.user.id, chapterId: chId },
        update: {
          $set: {
            ...(cleanMangaId ? { mangaId: cleanMangaId } : {}),
            completed: isRead,
            updatedAt: new Date(),
          },
          $setOnInsert: { page: 1, totalPages: 0, createdAt: new Date() },
        },
        upsert: true,
      },
    }));

    await Progress.bulkWrite(ops);
    res.json({ success: true, count: targetIds.length, read: isRead });
  } catch (err) {
    console.error('[Progress Read Status Error]', err.message);
    res.status(500).json({ error: 'Failed to update read status' });
  }
});

// GET /api/progress/chapter-bookmarks - Retrieve user's chapter bookmarks
router.get('/chapter-bookmarks', async (req, res) => {
  try {
    const chapterBookmarks = await getUserBookmarks(req.user.id);
    res.json({ chapterBookmarks });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// PUT /api/progress/chapter-bookmarks - Replace user's chapter bookmarks
router.put('/chapter-bookmarks', async (req, res) => {
  try {
    const raw = Array.isArray(req.body?.chapterBookmarks) ? req.body.chapterBookmarks : [];
    const clean = Array.from(
      new Set(raw.filter((id) => typeof id === 'string' && id.trim()).map((id) => id.trim())),
    ).slice(0, 5000);

    await ChapterBookmark.deleteMany({ user: req.user.id, chapterId: { $nin: clean } });
    if (clean.length > 0) {
      await ChapterBookmark.bulkWrite(
        clean.map((chapterId) => ({
          updateOne: {
            filter: { user: req.user.id, chapterId },
            update: { $setOnInsert: { user: req.user.id, chapterId } },
            upsert: true,
          },
        })),
        { ordered: false },
      );
    }
    await User.findByIdAndUpdate(req.user.id, { $set: { chapterBookmarks: [] } }).catch(() => {});
    res.json({ success: true, chapterBookmarks: clean });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// POST /api/progress/chapter-bookmarks/toggle - Toggle single chapter bookmark
router.post('/chapter-bookmarks/toggle', async (req, res) => {
  try {
    const { chapterId } = req.body || {};
    if (!chapterId || typeof chapterId !== 'string') {
      return res.status(400).json({ error: 'chapterId is required' });
    }
    const cleanId = chapterId.trim();
    const existing = await ChapterBookmark.findOne({ user: req.user.id, chapterId: cleanId });
    if (existing) {
      await ChapterBookmark.deleteOne({ _id: existing._id });
    } else {
      await ChapterBookmark.updateOne(
        { user: req.user.id, chapterId: cleanId },
        { $setOnInsert: { user: req.user.id, chapterId: cleanId } },
        { upsert: true },
      );
    }
    res.json({ success: true, bookmarked: !existing, chapterId: cleanId });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// GET /api/progress/manga/:mangaId(*) - All chapter progress for a given manga (supports slashes/ext: IDs)
router.get('/manga/:mangaId(*)', async (req, res) => {
  try {
    const mangaId = safeDecodeParam(req.params.mangaId);
    const records = await Progress.find({
      user: req.user.id,
      mangaId,
    }).sort({ updatedAt: -1 });

    const lastRead = records[0] || null;
    const completedChapterIds = records
      .filter((r) => r.completed)
      .map((r) => r.chapterId);

    res.json({
      mangaId,
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

// DELETE /api/progress/manga/:mangaId(*) - Remove history entries for a specific manga
router.delete('/manga/:mangaId(*)', async (req, res) => {
  try {
    const mangaId = safeDecodeParam(req.params.mangaId);
    await Progress.deleteMany({
      user: req.user.id,
      mangaId,
    });
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// DELETE /api/progress/history/:chapterId(*) - Remove specific history entry (supports slashes/ext: IDs)
router.delete('/history/:chapterId(*)', async (req, res) => {
  try {
    const chapterId = safeDecodeParam(req.params.chapterId);
    await Progress.findOneAndDelete({
      user: req.user.id,
      chapterId,
    });
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

export default router;
