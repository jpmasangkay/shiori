import express from 'express';
import {
  searchManga,
  getManga,
  getChapters,
  getChapterPages,
  UpstreamError,
} from '../services/mangadex.js';

const router = express.Router();

// GET /api/manga/search?q=...&type=manga|manhwa|manhua&order=popular|latest|rating|new&page=1&limit=24
router.get('/search', async (req, res) => {
  try {
    const { q, type, order, page, limit, tag } = req.query;
    const results = await searchManga({ q, type, order, page, limit, tag });
    res.json(results);
  } catch (err) {
    const status = err instanceof UpstreamError ? err.status : 500;
    res.status(status).json({ error: err.message });
  }
});

// GET /api/manga/:id
router.get('/:id', async (req, res) => {
  try {
    const manga = await getManga(req.params.id);
    res.json(manga);
  } catch (err) {
    const status = err instanceof UpstreamError ? err.status : 500;
    res.status(status).json({ error: err.message });
  }
});

// GET /api/manga/:id/chapters?lang=en
router.get('/:id/chapters', async (req, res) => {
  try {
    const lang = req.query.lang || 'en';
    const chapters = await getChapters(req.params.id, { lang });
    res.json({ mangaId: req.params.id, chapters, total: chapters.length });
  } catch (err) {
    const status = err instanceof UpstreamError ? err.status : 500;
    res.status(status).json({ error: err.message });
  }
});

// GET /api/manga/chapter/:id/pages
router.get('/chapter/:id/pages', async (req, res) => {
  try {
    const pages = await getChapterPages(req.params.id);
    res.json(pages);
  } catch (err) {
    const status = err instanceof UpstreamError ? err.status : 500;
    res.status(status).json({ error: err.message });
  }
});

export default router;
