import jwt from 'jsonwebtoken';
import mongoose from 'mongoose';
import { getJwtSecret } from '../config.js';
import { User } from '../models.js';

async function verifyTokenAndVersion(token) {
  const decoded = jwt.verify(token, getJwtSecret());
  if (typeof decoded?.tv === 'number' && mongoose.connection.readyState === 1) {
    const user = await User.findById(decoded.id).select('tokenVersion').lean();
    if (!user || (user.tokenVersion ?? 0) !== decoded.tv) {
      throw new Error('Token has been revoked');
    }
  }
  return decoded;
}

export async function requireAuth(req, res, next) {
  const header = req.headers.authorization;
  if (!header || !header.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Authentication required' });
  }

  const token = header.slice(7).trim();
  try {
    req.user = await verifyTokenAndVersion(token);
    return next();
  } catch {
    return res.status(401).json({ error: 'Invalid or expired token' });
  }
}

export async function optionalAuth(req, res, next) {
  const header = req.headers.authorization;
  if (!header || !header.startsWith('Bearer ')) {
    return next();
  }

  const token = header.slice(7).trim();
  try {
    req.user = await verifyTokenAndVersion(token);
  } catch {
    // Ignore invalid token for optional auth
  }
  return next();
}
