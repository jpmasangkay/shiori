import express from 'express';
import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';
import rateLimit from 'express-rate-limit';
import { ChapterBookmark, LibraryEntry, Progress, User, UserCategory } from '../models.js';
import { getJwtSecret } from '../config.js';
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
    {
      id: user._id.toString(),
      email: user.email,
      tv: user.tokenVersion ?? 0,
    },
    getJwtSecret(),
    { expiresIn: '30d' },
  );
}

// POST /api/auth/register
router.post('/register', authLimiter, async (req, res) => {
  try {
    const { email, password, displayName } = req.body || {};

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
      tokenVersion: 0,
    });

    const token = issueToken(user);
    return res.status(201).json({
      token,
      user: {
        id: user._id.toString(),
        email: user.email,
        displayName: user.displayName,
      },
    });
  } catch (err) {
    console.error('[Auth Register Error]', err.message);
    return res.status(500).json({ error: 'Registration failed. Please try again.' });
  }
});

// POST /api/auth/login
router.post('/login', authLimiter, async (req, res) => {
  try {
    const { email, password } = req.body || {};

    if (typeof email !== 'string' || typeof password !== 'string') {
      return res.status(400).json({ error: 'Valid email and password strings are required' });
    }

    const normalizedEmail = email.trim().toLowerCase();
    const user = await User.findOne({ email: normalizedEmail });
    if (!user) {
      return res.status(401).json({ error: 'Invalid email or password' });
    }

    if (password.length > 128) {
      return res.status(401).json({ error: 'Invalid email or password' });
    }

    const match = await bcrypt.compare(password, user.passwordHash);
    if (!match) {
      return res.status(401).json({ error: 'Invalid email or password' });
    }

    const token = issueToken(user);
    return res.json({
      token,
      user: {
        id: user._id.toString(),
        email: user.email,
        displayName: user.displayName,
      },
    });
  } catch (err) {
    console.error('[Auth Login Error]', err.message);
    return res.status(500).json({ error: 'Login failed. Please try again.' });
  }
});

// POST /api/auth/logout - Revokes all active JWTs by incrementing tokenVersion
router.post('/logout', requireAuth, async (req, res) => {
  try {
    await User.findByIdAndUpdate(req.user.id, { $inc: { tokenVersion: 1 } });
    return res.json({ success: true });
  } catch (err) {
    console.error('[Auth Logout Error]', err.message);
    return res.status(500).json({ error: 'Unable to revoke session' });
  }
});

// POST /api/auth/change-password - Change password and rotate tokenVersion
router.post('/change-password', authLimiter, requireAuth, async (req, res) => {
  try {
    const { currentPassword, newPassword } = req.body || {};
    if (typeof currentPassword !== 'string' || typeof newPassword !== 'string') {
      return res.status(400).json({ error: 'Current and new passwords are required' });
    }
    if (newPassword.length < 6 || newPassword.length > 128) {
      return res.status(400).json({ error: 'New password must be between 6 and 128 characters' });
    }
    const user = await User.findById(req.user.id);
    if (!user) {
      return res.status(404).json({ error: 'User not found' });
    }
    const match = await bcrypt.compare(currentPassword, user.passwordHash);
    if (!match) {
      return res.status(401).json({ error: 'Current password is incorrect' });
    }
    user.passwordHash = await bcrypt.hash(newPassword, await bcrypt.genSalt(10));
    user.tokenVersion = (user.tokenVersion ?? 0) + 1;
    await user.save();

    const token = issueToken(user);
    return res.json({
      success: true,
      token,
      user: {
        id: user._id.toString(),
        email: user.email,
        displayName: user.displayName,
      },
    });
  } catch (err) {
    console.error('[Auth Change Password Error]', err.message);
    return res.status(500).json({ error: 'Unable to update password' });
  }
});

// DELETE /api/auth/account - Permanently deletes user account and all synced data
router.delete('/account', authLimiter, requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    await Promise.all([
      LibraryEntry.deleteMany({ user: userId }),
      UserCategory.deleteMany({ user: userId }),
      Progress.deleteMany({ user: userId }),
      ChapterBookmark.deleteMany({ user: userId }),
      User.findByIdAndDelete(userId),
    ]);
    return res.json({ success: true });
  } catch (err) {
    console.error('[Auth Delete Account Error]', err.message);
    return res.status(500).json({ error: 'Unable to delete account' });
  }
});

// GET /api/auth/me
router.get('/me', requireAuth, async (req, res) => {
  try {
    const user = await User.findById(req.user.id).select('-passwordHash');
    if (!user) {
      return res.status(404).json({ error: 'User not found' });
    }
    return res.json({
      user: {
        id: user._id.toString(),
        email: user.email,
        displayName: user.displayName,
      },
    });
  } catch (err) {
    console.error('[Auth Me Error]', err.message);
    return res.status(500).json({ error: 'Unable to retrieve user profile' });
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
      decoded = jwt.verify(rawToken, getJwtSecret(), {
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
    if (typeof decoded.tv === 'number' && (user.tokenVersion ?? 0) !== decoded.tv) {
      return res.status(401).json({ error: 'Session revoked. Please sign in again.' });
    }

    const token = issueToken(user);
    return res.json({
      token,
      user: {
        id: user._id.toString(),
        email: user.email,
        displayName: user.displayName,
      },
    });
  } catch (err) {
    console.error('[Auth Refresh Error]', err.message);
    return res.status(500).json({ error: 'Unable to refresh session' });
  }
});

export default router;
