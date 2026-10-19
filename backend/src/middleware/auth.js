import jwt from 'jsonwebtoken';
import { config } from '../config.js';

export function requireAuth(req, res, next) {
  const header = req.headers.authorization;
  if (!header || !header.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Authentication required' });
  }

  const token = header.slice(7).trim();
  try {
    const decoded = jwt.verify(token, config.jwtSecret || 'dev-fallback-secret');
    req.user = decoded;
    next();
  } catch (err) {
    return res.status(401).json({ error: 'Invalid or expired token' });
  }
}

export function optionalAuth(req, res, next) {
  const header = req.headers.authorization;
  if (!header || !header.startsWith('Bearer ')) {
    return next();
  }

  const token = header.slice(7).trim();
  try {
    const decoded = jwt.verify(token, config.jwtSecret || 'dev-fallback-secret');
    req.user = decoded;
  } catch (err) {
    // Ignore invalid token for optional auth
  }
  next();
}
