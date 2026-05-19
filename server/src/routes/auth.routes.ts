import { Router } from 'express';
import { body } from 'express-validator';
import { register, login, refresh, logout, me } from '../controllers/auth.controller';
import { requireAuth } from '../middleware/auth.middleware';

const router = Router();

router.post(
  '/register',
  [
    body('email').isEmail().normalizeEmail(),
    body('password').isLength({ min: 8 }),
    body('name').optional().trim().notEmpty(),
  ],
  register
);

router.post(
  '/login',
  [
    body('email').isEmail().normalizeEmail(),
    body('password').notEmpty(),
  ],
  login
);

router.post('/refresh', body('refreshToken').notEmpty(), refresh);
router.post('/logout', requireAuth, logout);
router.get('/me', requireAuth, me);

export default router;
