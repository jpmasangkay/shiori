import express from 'express';
import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';
import rateLimit from 'express-rate-limit';
import { User } from '../models.js';
import { config } from '../config.js';
import { requireAuth } from '../middleware/auth.js';

const router = express.Router();

// Strict brute-force protection on authentication endpoints: 15 attempts / 15 mins
const authLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 15,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many authentication attempts. Please try again in 15 minutes.' },
});

const EMAIL_REGEX = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function issueToken(user) {
  return jwt.sign(
    { id: user._id.toString(), email: user.email },
    config.jwtSecret || 'dev-fallback-secret',
    { expiresIn: '30d' },
  );
}

// POST /api/auth/register
router.post('/register', authLimiter, async (req, res) => {
  try {
    const { email, password, displayName } = req.body;

    // Type validation to prevent NoSQL injection objects
    if (typeof email !== 'string' || typeof password !== 'string') {
      return res.status(400).json({ error: 'Valid email and password strings are required' });
    }

    const normalizedEmail = email.trim().toLowerCase();
    if (!EMAIL_REGEX.test(normalizedEmail)) {
      return res.status(400).json({ error: 'Please enter a valid email address' });
    }

    if (password.length < 6) {
      return res.status(400).json({ error: 'Password must be at least 6 characters' });
    }
    if (password.length > 128) {
      return res.status(400).json({ error: 'Password cannot exceed 128 characters' });
    }

    const existing = await User.findOne({ email: normalizedEmail });
    if (existing) {
      return res.status(409).json({ error: 'Email is already registered' });
    }

    const salt = await bcrypt.genSalt(10);
    const passwordHash = await bcrypt.hash(password, salt);

    const safeDisplayName = typeof displayName === 'string'
      ? displayName.trim().slice(0, 50)
      : '';

    const user = await User.create({
      email: normalizedEmail,
      passwordHash,
      displayName: safeDisplayName,
    });

    const token = issueToken(user);
    res.status(201).json({
      token,
      user: {
        id: user._id.toString(),
        email: user.email,
        displayName: user.displayName,
      },
    });
  } catch (err) {
    console.error('[Auth Register Error]', err.message);
    res.status(500).json({ error: 'Registration failed. Please try again.' });
  }
});

// POST /api/auth/login
router.post('/login', authLimiter, async (req, res) => {
  try {
    const { email, password } = req.body;

    if (typeof email !== 'string' || typeof password !== 'string') {
      return res.status(400).json({ error: 'Valid email and password strings are required' });
    }

    const normalizedEmail = email.trim().toLowerCase();
    const user = await User.findOne({ email: normalizedEmail });
    if (!user) {
      return res.status(401).json({ error: 'Invalid email or password' });
    }

    // Safety guard against oversized password calculation
    if (password.length > 128) {
      return res.status(401).json({ error: 'Invalid email or password' });
    }

    const match = await bcrypt.compare(password, user.passwordHash);
    if (!match) {
      return res.status(401).json({ error: 'Invalid email or password' });
    }

    const token = issueToken(user);
    res.json({
      token,
      user: {
        id: user._id.toString(),
        email: user.email,
        displayName: user.displayName,
      },
    });
  } catch (err) {
    console.error('[Auth Login Error]', err.message);
    res.status(500).json({ error: 'Login failed. Please try again.' });
  }
});

// GET /api/auth/me
router.get('/me', requireAuth, async (req, res) => {
  try {
    const user = await User.findById(req.user.id).select('-passwordHash');
    if (!user) {
      return res.status(404).json({ error: 'User not found' });
    }
    res.json({
      user: {
        id: user._id.toString(),
        email: user.email,
        displayName: user.displayName,
      },
    });
  } catch (err) {
    console.error('[Auth Me Error]', err.message);
    res.status(500).json({ error: 'Unable to retrieve user profile' });
  }
});

// POST /api/auth/refresh - Refresh active or recently expired JWT (within 7d grace window)
router.post('/refresh', authLimiter, async (req, res) => {
  try {
    const header = req.headers.authorization;
    if (!header || !header.startsWith('Bearer ')) {
      return res.status(401).json({ error: 'Authentication required' });
    }
    const rawToken = header.slice(7).trim();
    let decoded;
    try {
      decoded = jwt.verify(rawToken, config.jwtSecret || 'dev-fallback-secret', {
        ignoreExpiration: true,
      });
    } catch {
      return res.status(401).json({ error: 'Invalid token signature' });
    }

    const nowSec = Math.floor(Date.now() / 1000);
    const graceWindowSec = 7 * 24 * 60 * 60;
    if (decoded.exp && nowSec - decoded.exp > graceWindowSec) {
      return res.status(401).json({ error: 'Session expired. Please sign in again.' });
    }

    const user = await User.findById(decoded.id).select('-passwordHash');
    if (!user) {
      return res.status(401).json({ error: 'User account not found' });
    }

    const token = issueToken(user);
    res.json({
      token,
      user: {
        id: user._id.toString(),
        email: user.email,
        displayName: user.displayName,
      },
    });
  } catch (err) {
    console.error('[Auth Refresh Error]', err.message);
    res.status(500).json({ error: 'Unable to refresh session' });
  }
});

export default router;

