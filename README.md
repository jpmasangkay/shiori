# Shiori — Manga, Manhwa & Manhua Reader

A modern Flutter manga reader recreated faithfully from the Figma Make **Shiori UI Design**, featuring a high-performance **Material 3 Dark Theme**, live integration with the **free MangaDex API**, and a **Node.js + MongoDB backend** for user accounts, cloud library sync, chapter reading progress, and reading history.

---

## 📱 Features

- **5-Tab Navigation**:
  1. 📚 **Library**: Categories (*Default, Reading, Completed*), customizable grid columns (2 to 5), display modes (*Compact Grid, Comfortable Grid, Cover-only, List*), and sorting (*Alphabetical, Total Chapters, Date Added*).
  2. ⚡ **Updates**: Grouped timeline (*Today, Yesterday, Earlier*) of newly released chapters for bookmarked or trending series.
  3. ⏱️ **History**: Fast resume cards with reading progress and relative timestamps.
  4. 🔍 **Browse**: Real-time search with debouncing, language/origin filters:
     - 🇰🇷 **Manhwa** (`ko`)
     - 🇯🇵 **Manga** (`ja`)
     - 🇨🇳 **Manhua** (`zh`)
     - Sort by: *Popularity, Latest, Rating, Newly Added, Relevance*
  5. ⚙️ **More**: Authentication (Register/Login with JWT), MongoDB connection status indicator, configurable backend host URL, cache management, and download controls.

- **📖 Series Details**:
  - Blurred backdrop hero art with cover shadow
  - Expandable synopsis & genre chips
  - Action buttons (*In Library, Tracking, Share, Open in Browser*)
  - Live chapter feed with chapter numbers, upload groups, dates, and read badges
  - One-tap "Start Reading / Resume" FAB

- **🖼️ Built-in Manga Reader**:
  - Dual viewing modes: **Continuous Vertical Webtoon** scroll & **Horizontal Paged** swipe
  - Live high-resolution page loading via MangaDex At-Home server network
  - Page scrubber slider & persistent reading progress sync to MongoDB

---

## 🛠️ Tech Stack & Architecture

```
Finals/
├── lib/                             # Flutter Material 3 Frontend
│   ├── models/manga_models.dart     # Manga, Chapter, Pages & User models
│   ├── services/api_service.dart    # Singleton HTTP client, JWT auth, MongoDB sync
│   ├── screens/                     # Library, Updates, History, Browse, More, Detail, Reader
│   ├── widgets/common.dart          # Brand mark, badges, cached network covers
│   ├── theme.dart                   # Material 3 dark tokens matching Figma Make
│   └── main.dart                    # Application root & RootShell navigation
├── backend/                         # Node.js + Express + Mongoose REST API
│   ├── src/models.js                # MongoDB Schemas (User, LibraryEntry, Progress)
│   ├── src/services/mangadex.js     # Rate-throttled MangaDex client (230ms slot) + cache
│   ├── src/routes/                  # auth, manga, library, progress, updates
│   └── src/index.js                 # Express server on port 3000 with graceful degradation
└── test/                            # Full Flutter widget test suite (5 passing tests)
```

---

## 🚀 Getting Started

### 1. Backend Server Setup

The backend server is located in `backend/`:

```bash
cd backend
npm install
```

#### MongoDB Atlas Configuration
Create a free MongoDB database cluster on [MongoDB Atlas](https://www.mongodb.com/atlas):
1. Create a database user (e.g. `shiori_user`) and password.
2. Under **Network Access**, add `0.0.0.0/0` (Allow Access from Anywhere) or your current IP.
3. In `backend/.env`, set your connection string:
   ```env
   PORT=3000
   MONGODB_URI=mongodb+srv://<user>:<password>@cluster0.mongodb.net/shiori?retryWrites=true&w=majority
   JWT_SECRET=your-random-jwt-secret-key
   CORS_ORIGIN=*
   ```

> **Note**: The backend features **graceful degradation** — if `MONGODB_URI` is left unconfigured, public manga/manhwa/manhua browsing, search, and reading work out of the box. Configuring `MONGODB_URI` enables user registration, cloud library bookmarks, and cross-device reading progress.

#### Start the Server:
```bash
node src/index.js
```
The server will listen at `http://localhost:3000`.

---

### 2. Run the Flutter App

From the project root:

```bash
# Verify static analysis & tests
flutter analyze
flutter test

# Run on macOS desktop:
flutter run -d macos

# Or run on Chrome / Web:
flutter run -d chrome

# Or run on connected iOS / Android device:
flutter run
```

---

### 3. API Host Configuration in App
- By default, the app targets:
  - `http://localhost:3000/api` on desktop and iOS.
  - `http://10.0.2.2:3000/api` on the Android emulator.
- You can change the API host at any time in the app under **More > Network & Backend > API Server Host**.

