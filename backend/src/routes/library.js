import express from 'express';
import { LibraryEntry, UserCategory } from '../models.js';
import { requireAuth } from '../middleware/auth.js';

const router = express.Router();

router.use(requireAuth);

const VALID_TYPES = new Set(['manga', 'manhwa', 'manhua']);

function sanitizeType(raw) {
  const normalized = typeof raw === 'string' ? raw.trim().toLowerCase() : 'manga';
  return VALID_TYPES.has(normalized) ? normalized : 'manga';
}

function sanitizeCategories(raw) {
  if (!Array.isArray(raw)) return undefined;
  return raw
    .filter((id) => typeof id === 'string' && id.trim().length > 0)
    .map((id) => id.trim().slice(0, 80))
    .slice(0, 50);
}

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

// GET /api/library/categories - Fetch user's custom categories & manga category assignments
router.get('/categories', async (req, res) => {
  try {
    const [categories, entries] = await Promise.all([
      UserCategory.find({ user: req.user.id }).sort({ order: 1, createdAt: 1 }),
      LibraryEntry.find({ user: req.user.id, 'categories.0': { $exists: true } }).select(
        'mangaId categories',
      ),
    ]);
    const mangaCategories = {};
    for (const entry of entries) {
      if (Array.isArray(entry.categories) && entry.categories.length > 0) {
        mangaCategories[entry.mangaId] = entry.categories;
      }
    }
    res.json({
      categories: categories.map((c) => ({
        id: c.categoryId,
        name: c.name,
        order: c.order,
      })),
      mangaCategories,
    });
  } catch (err) {
    console.error('[Library Categories Get Error]', err.message);
    res.status(500).json({ error: 'Failed to fetch categories' });
  }
});

// PUT /api/library/categories - Sync custom categories & optional manga category assignments
router.put('/categories', async (req, res) => {
  try {
    const { categories, mangaCategories } = req.body || {};

    if (Array.isArray(categories)) {
      const sanitized = categories
        .filter(
          (c) =>
            c &&
            typeof c.id === 'string' &&
            c.id.trim() &&
            typeof c.name === 'string' &&
            c.name.trim(),
        )
        .slice(0, 100)
        .map((c, idx) => ({
          categoryId: c.id.trim().slice(0, 80),
          name: c.name.trim().slice(0, 60),
          order: typeof c.order === 'number' ? c.order : idx,
        }));

      const defaultIds = ['reading', 'completed', 'plan_to_read', 'favorites'];
      const keepIds = [...new Set([...sanitized.map((c) => c.categoryId), ...defaultIds])];
      await UserCategory.deleteMany({
        user: req.user.id,
        categoryId: { $nin: keepIds },
      });

      if (sanitized.length > 0) {
        await UserCategory.bulkWrite(
          sanitized.map((c) => ({
            updateOne: {
              filter: { user: req.user.id, categoryId: c.categoryId },
              update: { $set: { name: c.name, order: c.order } },
              upsert: true,
            },
          })),
        );
      }
    }

    if (mangaCategories && typeof mangaCategories === 'object' && !Array.isArray(mangaCategories)) {
      const entries = Object.entries(mangaCategories).slice(0, 500);
      const ops = [];
      for (const [mangaId, catList] of entries) {
        const cleanId = String(mangaId).trim();
        const cleanCats = sanitizeCategories(catList);
        if (!cleanId || !cleanCats) continue;
        ops.push({
          updateOne: {
            filter: { user: req.user.id, mangaId: cleanId },
            update: { $set: { categories: cleanCats } },
          },
        });
      }
      if (ops.length > 0) {
        await LibraryEntry.bulkWrite(ops);
      }
    }

    res.json({ success: true });
  } catch (err) {
    console.error('[Library Categories Put Error]', err.message);
    res.status(500).json({ error: 'Failed to sync categories' });
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

// POST /api/library/batch - Batch upsert library bookmarks in a single round-trip
router.post('/batch', async (req, res) => {
  try {
    const rawItems = Array.isArray(req.body?.items) ? req.body.items : [];
    if (rawItems.length === 0) {
      return res.json({ upserted: 0 });
    }

    const ops = [];
    for (const item of rawItems.slice(0, 500)) {
      if (!item || typeof item.mangaId !== 'string' || typeof item.title !== 'string') continue;
      const cleanMangaId = item.mangaId.trim();
      const cleanTitle = item.title.trim().slice(0, 200);
      if (!cleanMangaId || !cleanTitle) continue;

      const setFields = {
        title: cleanTitle,
        type: sanitizeType(item.type),
        status: typeof item.status === 'string' ? item.status.trim() : '',
        source: typeof item.source === 'string' ? item.source.trim().slice(0, 80) : '',
        chapterCount: Number(item.chapterCount) || 0,
        latestChapter: typeof item.latestChapter === 'string' ? item.latestChapter.trim() : '',
      };
      if (typeof item.cover === 'string' && item.cover.trim().length > 0) {
        setFields.cover = item.cover.trim();
      }
      const cleanCats = sanitizeCategories(item.categories);
      if (cleanCats !== undefined) {
        setFields.categories = cleanCats;
      }

      ops.push({
        updateOne: {
          filter: { user: req.user.id, mangaId: cleanMangaId },
          update: {
            $set: setFields,
            $setOnInsert: { addedAt: new Date() },
          },
          upsert: true,
        },
      });
    }

    if (ops.length > 0) {
      await LibraryEntry.bulkWrite(ops);
    }

    res.status(201).json({ success: true, count: ops.length });
  } catch (err) {
    console.error('[Library Batch Save Error]', err.message);
    res.status(500).json({ error: 'Failed to batch update library' });
  }
});

// POST /api/library
router.post('/', async (req, res) => {
  try {
    const { mangaId, title, cover, type, status, source, chapterCount, latestChapter, categories } =
      req.body;
    if (typeof mangaId !== 'string' || typeof title !== 'string' || !mangaId.trim() || !title.trim()) {
      return res.status(400).json({ error: 'Valid mangaId and title are required' });
    }

    const cleanMangaId = mangaId.trim();
    const cleanTitle = title.trim().slice(0, 200);
    const setFields = {
      title: cleanTitle,
      type: sanitizeType(type),
      status: typeof status === 'string' ? status.trim() : '',
      source: typeof source === 'string' ? source.trim().slice(0, 80) : '',
      chapterCount: Number(chapterCount) || 0,
      latestChapter: typeof latestChapter === 'string' ? latestChapter.trim() : '',
    };
    if (typeof cover === 'string' && cover.trim().length > 0) {
      setFields.cover = cover.trim();
    }
    const cleanCats = sanitizeCategories(categories);
    if (cleanCats !== undefined) {
      setFields.categories = cleanCats;
    }

    const entry = await LibraryEntry.findOneAndUpdate(
      { user: req.user.id, mangaId: cleanMangaId },
      {
        $set: setFields,
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

// Helper function for library entry removal
async function handleRemoveLibraryEntry(req, res, rawMangaId) {
  try {
    const mangaId = String(rawMangaId || '').trim();
    if (!mangaId) {
      return res.status(400).json({ error: 'Valid mangaId is required' });
    }
    await LibraryEntry.findOneAndDelete({
      user: req.user.id,
      mangaId,
    });
    res.json({ success: true, removed: mangaId });
  } catch (err) {
    console.error('[Library Delete Error]', err.message);
    res.status(500).json({ error: 'Failed to remove from library' });
  }
}

// POST /api/library/remove - Safe removal endpoint handling any manga ID with slashes/colons
router.post('/remove', async (req, res) => {
  await handleRemoveLibraryEntry(req, res, req.body?.mangaId || req.query?.mangaId);
});

// DELETE /api/library - Deletion via query param or body
router.delete('/', async (req, res) => {
  await handleRemoveLibraryEntry(req, res, req.query?.mangaId || req.body?.mangaId);
});

// DELETE /api/library/:mangaId(*) - Supports wildcards and slashes in mangaId
router.delete('/:mangaId(*)', async (req, res) => {
  await handleRemoveLibraryEntry(req, res, req.params.mangaId);
});

export default router;

