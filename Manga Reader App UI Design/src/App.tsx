import { useState } from "react";

type IconName =
  | "arrow"
  | "bookmark"
  | "brightness"
  | "check"
  | "chevron"
  | "crop"
  | "download"
  | "filter"
  | "globe"
  | "grid"
  | "heart"
  | "history"
  | "library"
  | "list"
  | "more"
  | "play"
  | "refresh"
  | "rotation"
  | "search"
  | "settings"
  | "share"
  | "sort"
  | "sync";

const paths: Record<IconName, React.ReactNode> = {
  arrow: <path d="m15 18-6-6 6-6M9 12h11" />,
  bookmark: <path d="M6 4.5A1.5 1.5 0 0 1 7.5 3h9A1.5 1.5 0 0 1 18 4.5V21l-6-3.8L6 21Z" />,
  brightness: <><circle cx="12" cy="12" r="4" /><path d="M12 2v2m0 16v2M4.93 4.93l1.41 1.41m11.32 11.32 1.41 1.41M2 12h2m16 0h2M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41" /></>,
  check: <path d="m5 12 4 4L19 6" />,
  chevron: <path d="m8 10 4 4 4-4" />,
  crop: <path d="M6 2v16a2 2 0 0 0 2 2h14M2 6h16a2 2 0 0 1 2 2v14" />,
  download: <path d="M12 3v12m0 0 4-4m-4 4-4-4M5 21h14" />,
  filter: <path d="M4 6h16M7 12h10m-7 6h4" />,
  globe: <><circle cx="12" cy="12" r="9" /><path d="M3 12h18M12 3a15 15 0 0 1 0 18m0-18a15 15 0 0 0 0 18" /></>,
  grid: <><rect x="3" y="3" width="7" height="7" rx="1" /><rect x="14" y="3" width="7" height="7" rx="1" /><rect x="3" y="14" width="7" height="7" rx="1" /><rect x="14" y="14" width="7" height="7" rx="1" /></>,
  heart: <path d="M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.7l-1.1-1.1a5.5 5.5 0 0 0-7.8 7.8l1.1 1.1L12 21l7.8-7.5 1.1-1.1a5.5 5.5 0 0 0-.1-7.8Z" />,
  history: <><path d="M3 12a9 9 0 1 0 3-6.7L3 8" /><path d="M3 3v5h5M12 7v5l3 2" /></>,
  library: <><path d="M4 5h5v15H4zM10 5h5v15h-5zM16 4l4-1 2 15-4 1z" /></>,
  list: <><path d="M9 6h11M9 12h11M9 18h11" /><circle cx="4" cy="6" r="1" /><circle cx="4" cy="12" r="1" /><circle cx="4" cy="18" r="1" /></>,
  more: <><circle cx="12" cy="5" r="1" /><circle cx="12" cy="12" r="1" /><circle cx="12" cy="19" r="1" /></>,
  play: <path d="m8 5 11 7-11 7Z" />,
  refresh: <><path d="M20 7h-6V1" /><path d="M20 7a9 9 0 1 0 1 8" /></>,
  rotation: <><path d="M21 12a9 9 0 0 0-15.5-6.2L3 8" /><path d="M3 3v5h5M3 12a9 9 0 0 0 15.5 6.2L21 16" /><path d="M21 21v-5h-5" /></>,
  search: <><circle cx="11" cy="11" r="7" /><path d="m20 20-4-4" /></>,
  settings: <><circle cx="12" cy="12" r="3" /><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1-2.8 2.8-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.6v.2h-4V21a1.7 1.7 0 0 0-1-1.6 1.7 1.7 0 0 0-1.9.3l-.1.1L4.2 17l.1-.1a1.7 1.7 0 0 0 .3-1.9A1.7 1.7 0 0 0 3 14H2.8v-4H3a1.7 1.7 0 0 0 1.6-1 1.7 1.7 0 0 0-.3-1.9L4.2 7 7 4.2l.1.1A1.7 1.7 0 0 0 9 4.6a1.7 1.7 0 0 0 1-1.6v-.2h4V3a1.7 1.7 0 0 0 1 1.6 1.7 1.7 0 0 0 1.9-.3l.1-.1L19.8 7l-.1.1a1.7 1.7 0 0 0-.3 1.9 1.7 1.7 0 0 0 1.6 1h.2v4H21a1.7 1.7 0 0 0-1.6 1Z" /></>,
  share: <><circle cx="18" cy="5" r="2" /><circle cx="6" cy="12" r="2" /><circle cx="18" cy="19" r="2" /><path d="m8 11 8-5m-8 7 8 5" /></>,
  sort: <path d="M4 7h10M4 12h7M4 17h4m8-5 3 3 3-3m-3-6v9" />,
  sync: <><path d="M20 7h-5l2-2a7 7 0 0 0-11 2" /><path d="M4 17h5l-2 2a7 7 0 0 0 11-2" /></>,
};

function Icon({ name, size = 20, filled = false }: { name: IconName; size?: number; filled?: boolean }) {
  return <svg aria-hidden="true" className={filled ? "filled" : ""} viewBox="0 0 24 24" width={size} height={size}>{paths[name]}</svg>;
}

function IconButton({ name, label, onClick }: { name: IconName; label: string; onClick?: () => void }) {
  return <button className="icon-button" aria-label={label} onClick={onClick}><Icon name={name} /></button>;
}

function BrandMark({ size = 28 }: { size?: number }) {
  return <svg className="brand-mark" aria-label="Shiori" viewBox="0 0 32 32" width={size} height={size}>
    <path className="brand-tile" d="M7 3h18a4 4 0 0 1 4 4v18a4 4 0 0 1-4 4H7a4 4 0 0 1-4-4V7a4 4 0 0 1 4-4Z" />
    <path className="brand-page" d="M10 8.5h12v16l-6-4-6 4Z" />
    <path className="brand-fold" d="m16 8.5 6 5.5h-6Z" />
  </svg>;
}

const photos = [
  "https://images.unsplash.com/photo-1774106785831-fd50721a93f1?auto=format&fit=crop&w=360&q=75",
  "https://images.unsplash.com/photo-1763169964995-9c86fbbc6d45?auto=format&fit=crop&w=360&q=75",
  "https://images.unsplash.com/photo-1783240129674-8eaa33fa1948?auto=format&fit=crop&w=360&q=75",
  "https://images.unsplash.com/photo-1766416994171-d28aa34e5dca?auto=format&fit=crop&w=360&q=75",
  "https://images.unsplash.com/photo-1783869056336-587ba2bff618?auto=format&fit=crop&w=360&q=75",
  "https://images.unsplash.com/photo-1771830916716-5a5cbd1f9d4d?auto=format&fit=crop&w=360&q=75",
  "https://images.unsplash.com/photo-1783869056326-6c64aa5e1362?auto=format&fit=crop&w=360&q=75",
  "https://images.unsplash.com/photo-1790823919870-d99671c757e1?auto=format&fit=crop&w=360&q=75",
  "https://images.unsplash.com/photo-1780587481036-b69dd8781402?auto=format&fit=crop&w=360&q=75",
];

const titles = ["The Breaker: Eternal Force", "Omniscient Reader", "Return of the Mount Hua Sect", "The S-Classes That I Raised", "Nano Machine", "Legend of the Northern Blade", "Mercenary Enrollment", "Eleceed", "The World After the Fall"];

function AppBar({ title, back = false, branded = false, actions = ["search", "filter", "more"] as IconName[] }: { title: string; back?: boolean; branded?: boolean; actions?: IconName[] }) {
  return <div className="app-bar">{back && <IconButton name="arrow" label="Back" />}{branded && <BrandMark size={28} />}<div className="app-title">{title}</div><div className="bar-actions">{actions.map((a) => <IconButton key={a} name={a} label={a} />)}</div></div>;
}

const nav = [["library", "Library"], ["refresh", "Updates"], ["history", "History"], ["globe", "Browse"], ["more", "More"]] as [IconName, string][];
function BottomNav({ active }: { active: string }) {
  return <div className="bottom-nav">{nav.map(([icon, label]) => <button className={`nav-item ${active === label ? "active" : ""}`} key={label}><span><Icon name={icon} size={20} /></span><small>{label}</small></button>)}</div>;
}

function CoverCard({ i }: { i: number }) {
  return <div className="cover-card"><img src={photos[i % photos.length]} alt="" /><div className="badge"><span>{i + 2}</span><b>{i % 3 + 1}</b></div><div className="cover-title">{titles[i % titles.length]}</div></div>;
}

function LibraryContent() {
  const [tab, setTab] = useState("Reading 14");
  return <><AppBar title="Library" branded /><div className="tabs">{["Reading 14", "Manhwa 42", "Manga 28", "Manhua 9", "Completed"].map((x) => <button onClick={() => setTab(x)} className={tab === x ? "selected" : ""} key={x}>{x}</button>)}</div><div className="library-grid">{Array.from({ length: 12 }, (_, i) => <CoverCard key={i} i={i} />)}</div></>;
}

function LibraryScreen() {
  return <Screen label="01 / LIBRARY"><LibraryContent /><BottomNav active="Library" /></Screen>;
}

function Action({ icon, label, active = false }: { icon: IconName; label: string; active?: boolean }) {
  return <button className={`detail-action ${active ? "accent" : ""}`}><Icon name={icon} filled={active} /><span>{label}</span></button>;
}

function Chapter({ num, title, meta, read = false, state = "download" }: { num: number; title: string; meta: string; read?: boolean; state?: string }) {
  return <div className={`chapter ${read ? "read" : ""}`}><div><div>Chapter {num} - {title}</div><small>{meta}</small></div><button className={`download-state ${state}`} aria-label="Download chapter">{state === "check" ? <Icon name="check" size={17} /> : state === "progress" ? <span /> : <Icon name="download" size={17} />}</button></div>;
}

function DetailScreen() {
  return <Screen label="02 / SERIES"><div className="detail-hero"><div className="hero-backdrop" style={{ backgroundImage: `url(${photos[0]})` }} /><AppBar title="" back actions={["share", "more"]} /><div className="series-intro"><img src={photos[0]} alt="The Breaker: Eternal Force cover" /><div><div className="series-title">The Breaker:<br />Eternal Force</div><div className="author">Jeon Geuk-jin · Park Jin-hwan</div><div className="status"><span /> Ongoing · Asura Scans</div></div></div></div><div className="action-row"><Action icon="heart" label="In Library" active /><Action icon="sync" label="Tracking" /><Action icon="globe" label="WebView" /><Action icon="share" label="Share" /></div><div className="synopsis">After his master disappears, a reluctant student is pulled back into the hidden world of martial arts. A new generation gathers around him as old enemies return.<Icon name="chevron" size={16} /></div><div className="chips">{["Seinen", "Action", "Martial Arts", "Regression"].map(x => <span key={x}>{x}</span>)}</div><div className="section-title"><b>184 Chapters</b><IconButton name="sort" label="Sort and filter" /></div><div className="chapter-list"><Chapter num={184} title="The Final Gate" meta="Today · 32 pages" /><Chapter num={183} title="Unbroken Resolve" meta="Yesterday · 28 pages" state="progress" /><Chapter num={182} title="The Visitor" meta="Oct 14 · 31 pages" read state="check" /><Chapter num={181} title="A Quiet Warning" meta="Oct 10 · 26 pages" read state="check" /><Chapter num={180} title="Path of the Dragon" meta="Oct 6 · 34 pages" read /></div><button className="resume-fab"><Icon name="play" size={19} filled />Resume Ch. 142</button></Screen>;
}

const updateRows = [
  [2, "Solo Leveling: Ragnarok", "Chapter 92 · Flame Comics"],
  [4, "Nano Machine", "Chapter 248 · Asura Scans"],
  [0, "The Breaker: Eternal Force", "Chapter 184 · Reaper Scans"],
  [6, "Mercenary Enrollment", "Chapter 211 · Luminous Scans"],
  [1, "Omniscient Reader", "Chapter 231 · Flame Comics"],
  [7, "Eleceed", "Chapter 324 · Void Scans"],
  [5, "Legend of the Northern Blade", "Chapter 202 · Leviatan"],
];
function UpdateRow({ row }: { row: (string | number)[] }) {
  return <div className="update-row"><img src={photos[row[0] as number]} alt="" /><div><b>{row[1]}</b><small>{row[2]}</small></div><IconButton name="download" label="Download chapter" /></div>;
}
function UpdatesScreen() {
  return <Screen label="03 / UPDATES"><AppBar title="Updates" actions={["refresh"]} /><div className="feed"><div className="date">Today</div>{updateRows.slice(0, 3).map((r, i) => <UpdateRow key={i} row={r} />)}<div className="date">Yesterday</div>{updateRows.slice(3, 5).map((r, i) => <UpdateRow key={i} row={r} />)}<div className="date">Oct 14</div>{updateRows.slice(5).map((r, i) => <UpdateRow key={i} row={r} />)}<div className="skeleton"><i /><span><i /><i /></span></div><div className="skeleton"><i /><span><i /><i /></span></div></div><BottomNav active="Updates" /></Screen>;
}

function ReaderScreen() {
  const [page, setPage] = useState(8);
  return <Screen label="04 / READER" className="reader"><div className="comic-art"><div className="moon" /><div className="ridge r1" /><div className="ridge r2" /><div className="ink-figure"><span /></div><div className="speech">You should not<br />have come here.</div><div className="panel-line" /></div><div className="reader-top"><IconButton name="arrow" label="Back" /><div><b>The Breaker: Eternal Force</b><small>Chapter 142 · Page {page}/24</small></div><IconButton name="bookmark" label="Bookmark" /><IconButton name="globe" label="WebView" /></div><div className="reader-bottom"><div className="scrubber"><button onClick={() => setPage(Math.max(1, page - 1))}>‹</button><input aria-label="Page" type="range" min="1" max="24" value={page} onChange={(e) => setPage(Number(e.target.value))} /><span>{page} / 24</span><button onClick={() => setPage(Math.min(24, page + 1))}>›</button></div><div className="reader-tools">{[["list", "Mode"], ["crop", "Crop"], ["grid", "Layout"], ["brightness", "Filter"], ["settings", "Settings"]].map(([icon, label]) => <button key={label}><Icon name={icon as IconName} /><small>{label}</small></button>)}</div></div></Screen>;
}

function ToggleRow({ label, initial = true }: { label: string; initial?: boolean }) {
  const [on, setOn] = useState(initial);
  return <button className="toggle-row" onClick={() => setOn(!on)}><span>{label}</span><i className={on ? "on" : ""}><b /></i></button>;
}
function SheetScreen() {
  const [mode, setMode] = useState("Compact Grid");
  const [cols, setCols] = useState(3);
  return <Screen label="05 / DISPLAY" className="sheet-screen"><div className="dim-library"><LibraryContent /></div><div className="scrim" /><div className="sheet"><div className="handle" /><div className="sheet-tabs"><span>Filter</span><span>Sort</span><span className="active">Display</span></div><div className="sheet-body"><div className="sheet-section"><div className="sheet-heading">Display mode</div><div className="mode-grid">{["Compact Grid", "Comfortable Grid", "Cover-only Grid", "List"].map(x => <button onClick={() => setMode(x)} className={mode === x ? "active" : ""} key={x}>{mode === x && <Icon name="check" size={16} />}{x}</button>)}</div></div><div className="sheet-section columns"><div className="sheet-heading">Grid size</div><div className="column-label">Columns: <b>{cols} per row</b></div><input type="range" min="2" max="5" step="1" value={cols} onChange={e => setCols(Number(e.target.value))} /><div className="steps"><i /><i /><i /><i /></div></div><div className="sheet-section"><div className="sheet-heading">Overlay badges</div><ToggleRow label="Unread count" /><ToggleRow label="Downloaded chapters" /><ToggleRow label="Local source badge" initial={false} /><ToggleRow label="Category tabs" /></div></div></div></Screen>;
}

function Screen({ children, label, className = "" }: { children: React.ReactNode; label: string; className?: string }) {
  return <div className="screen-wrap"><div className="screen-label">{label}</div><div className={`phone ${className}`}>{children}</div></div>;
}

export default function App() {
  return <main className="showcase"><header className="showcase-header"><div className="brand-lockup"><BrandMark size={44} /><div><span>SHIORI / ANDROID</span><b>Manga reader interface suite</b></div></div><div>Material 3 · Dark · 390 × 844</div></header><div className="screens"><LibraryScreen /><DetailScreen /><UpdatesScreen /><ReaderScreen /><SheetScreen /></div></main>;
}
