import mongoose from 'mongoose';

const userSchema = new mongoose.Schema(
  {
    email: { type: String, required: true, unique: true, lowercase: true, trim: true },
    passwordHash: { type: String, required: true },
    displayName: { type: String, trim: true, maxlength: 40, default: '' },
  },
  { timestamps: true },
);

export const User = mongoose.model('User', userSchema);

const librarySchema = new mongoose.Schema(
  {
    user: { type: mongoose.Schema.Types.ObjectId, ref: 'User', required: true },
    mangaId: { type: String, required: true },
    title: { type: String, required: true },
    cover: { type: String, default: '' },
    type: { type: String, enum: ['manga', 'manhwa', 'manhua'], default: 'manga' },
    status: { type: String, default: '' },
    chapterCount: { type: Number, default: 0 },
    latestChapter: { type: String, default: '' },
    addedAt: { type: Date, default: Date.now },
  },
  { timestamps: true },
);
librarySchema.index({ user: 1, mangaId: 1 }, { unique: true });
librarySchema.index({ user: 1, addedAt: -1 });

export const LibraryEntry = mongoose.model('LibraryEntry', librarySchema);

/** One document per (user, chapter): powers read marks, resume and History. */
const progressSchema = new mongoose.Schema(
  {
    user: { type: mongoose.Schema.Types.ObjectId, ref: 'User', required: true },
    mangaId: { type: String, required: true },
    chapterId: { type: String, required: true },
    mangaTitle: { type: String, default: '' },
    cover: { type: String, default: '' },
    chapterNumber: { type: String, default: '' },
    chapterTitle: { type: String, default: '' },
    page: { type: Number, default: 1 },
    totalPages: { type: Number, default: 0 },
    completed: { type: Boolean, default: false },
  },
  { timestamps: true },
);
progressSchema.index({ user: 1, chapterId: 1 }, { unique: true });
progressSchema.index({ user: 1, mangaId: 1 });
progressSchema.index({ user: 1, updatedAt: -1 });

export const Progress = mongoose.model('Progress', progressSchema);
