import express from 'express';
import { LibraryEntry } from '../models.js';
import { requireAuth } from '../middleware/auth.js';

const router = express.Router();

router.use(requireAuth);

// GET /api/library?type=manga|manhwa|manhua
router.get('/', async (req, res) => {
  try {
    const filter = { user: req.user.id };
    if (req.query.type) {
      filter.type = req.query.type;
    }
    const entries = await LibraryEntry.find(filter).sort({ addedAt: -1 });
    res.json({ items: entries, total: entries.length });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// GET /api/library/check/:mangaId
router.get('/check/:mangaId', async (req, res) => {
  try {
    const entry = await LibraryEntry.findOne({
      user: req.user.id,
      mangaId: req.params.mangaId,
    });
    res.json({ inLibrary: !!entry, entry });
  } catch (err) {
    console.error('[Library Check Error]', err.message);
    res.status(500).json({ error: 'Failed to check library status' });
  }
});

// POST /api/library
router.post('/', async (req, res) => {
  try {
    const { mangaId, title, cover, type, status, chapterCount, latestChapter } = req.body;
    if (typeof mangaId !== 'string' || typeof title !== 'string' || !mangaId.trim() || !title.trim()) {
      return res.status(400).json({ error: 'Valid mangaId and title are required' });
    }

    const cleanMangaId = mangaId.trim();
    const cleanTitle = title.trim().slice(0, 200);

    const entry = await LibraryEntry.findOneAndUpdate(
      { user: req.user.id, mangaId: cleanMangaId },
      {
        $set: {
          title: cleanTitle,
          cover: typeof cover === 'string' ? cover.trim() : '',
          type: typeof type === 'string' ? type.trim() : 'manga',
          status: typeof status === 'string' ? status.trim() : '',
          chapterCount: Number(chapterCount) || 0,
          latestChapter: typeof latestChapter === 'string' ? latestChapter.trim() : '',
        },
        $setOnInsert: { addedAt: new Date() },
      },
      { upsert: true, new: true, setDefaultsOnInsert: true },
    );

    res.status(201).json(entry);
  } catch (err) {
    console.error('[Library Save Error]', err.message);
    res.status(500).json({ error: 'Failed to update library' });
  }
});

// DELETE /api/library/:mangaId
router.delete('/:mangaId', async (req, res) => {
  try {
    const mangaId = String(req.params.mangaId).trim();
    const result = await LibraryEntry.findOneAndDelete({
      user: req.user.id,
      mangaId,
    });
    if (!result) {
      return res.status(404).json({ error: 'Entry not found in library' });
    }
    res.json({ success: true, removed: mangaId });
  } catch (err) {
    console.error('[Library Delete Error]', err.message);
    res.status(500).json({ error: 'Failed to remove from library' });
  }
});

export default router;

