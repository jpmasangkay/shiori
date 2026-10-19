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
      chapterNumber,
      chapterTitle,
      page,
      totalPages,
      completed,
    } = req.body;

    if (typeof mangaId !== 'string' || typeof chapterId !== 'string' || !mangaId.trim() || !chapterId.trim()) {
      return res.status(400).json({ error: 'Valid mangaId and chapterId are required' });
    }

    const cleanMangaId = mangaId.trim();
    const cleanChapterId = chapterId.trim();

    const doc = await Progress.findOneAndUpdate(
      { user: req.user.id, chapterId: cleanChapterId },
      {
        $set: {
          mangaId: cleanMangaId,
          mangaTitle: typeof mangaTitle === 'string' ? mangaTitle.trim().slice(0, 200) : '',
          cover: typeof cover === 'string' ? cover.trim() : '',
          chapterNumber: typeof chapterNumber === 'string' ? chapterNumber.trim() : String(chapterNumber || ''),
          chapterTitle: typeof chapterTitle === 'string' ? chapterTitle.trim().slice(0, 200) : '',
          page: Math.max(1, Number(page) || 1),
          totalPages: Math.max(0, Number(totalPages) || 0),
          completed: Boolean(completed),
        },
      },
      { upsert: true, new: true, setDefaultsOnInsert: true },
    );

    res.json(doc);
  } catch (err) {
    console.error('[Progress Save Error]', err.message);
    res.status(500).json({ error: 'Failed to update reading progress' });
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
      progressMap: Object.fromEntries(
        records.map((r) => [
          r.chapterId,
          { page: r.page, totalPages: r.totalPages, completed: r.completed },
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
    const limit = Math.min(Number(req.query.limit) || 50, 100);
    const history = await Progress.find({ user: req.user.id })
      .sort({ updatedAt: -1 })
      .limit(limit);

    res.json({ items: history, total: history.length });
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
