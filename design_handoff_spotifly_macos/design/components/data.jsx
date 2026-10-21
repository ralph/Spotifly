// Sample data — original (not real Spotify content)
// Cover art is generated as colored SVG placeholders to avoid copyright.

const COVERS = [
  { id: "c1", title: "Paper Cities", artist: "Liam Mercer",        hue: 14,  pattern: "stripes",   year: 2024, tracks: 12 },
  { id: "c2", title: "Short n' Honey",artist: "Carmen Sabra",      hue: 36,  pattern: "blob",      year: 2023, tracks: 10 },
  { id: "c3", title: "The Life Of",   artist: "Taylor Wren",       hue: 320, pattern: "split",     year: 2024, tracks: 14 },
  { id: "c4", title: "Unplugged Live",artist: "Liam Mercer",       hue: 160, pattern: "grain",     year: 2022, tracks: 18 },
  { id: "c5", title: "Setlist",       artist: "P!nx",              hue: 340, pattern: "halftone",  year: 2021, tracks: 22 },
  { id: "c6", title: "Dookie",        artist: "Greenfield",        hue: 200, pattern: "clouds",    year: 1994, tracks: 14 },
  { id: "c7", title: "Time of Our…",  artist: "Mira Cyril",        hue: 12,  pattern: "portrait",  year: 2020, tracks: 11 },
  { id: "c8", title: "Demotape",      artist: "Bandsalat",         hue: 50,  pattern: "tape",      year: 2003, tracks: 18 },
  { id: "c9", title: "King for a King",artist: "Will Vallée",      hue: 80,  pattern: "field",     year: 2019, tracks: 11 },
  { id: "c10",title: "Not That Simple",artist: "Micah Posner",     hue: 28,  pattern: "blob",      year: 2018, tracks: 9  },
  { id: "c11",title: "Shallow",       artist: "Lady Gala",         hue: 0,   pattern: "split",     year: 2018, tracks: 1  },
  { id: "c12",title: "Hijos Del Sol", artist: "Hermanos Gutman",   hue: 24,  pattern: "field",     year: 2022, tracks: 12 },
  { id: "c13",title: "Synergy",       artist: "Tash Sultan",       hue: 280, pattern: "halftone",  year: 2020, tracks: 8  },
  { id: "c14",title: "Cannonball",    artist: "Damian Rye",        hue: 40,  pattern: "blob",      year: 2017, tracks: 11 },
  { id: "c15",title: "The Letter",    artist: "Xavier Reed",       hue: 100, pattern: "field",     year: 2020, tracks: 9  },
];

const findCover = (id) => COVERS.find(c => c.id === id) || COVERS[0];

const ARTISTS = [
  { id: "a1", name: "Liam Mercer",     tags: "britpop · manchester", hue: 220, monthly: "8.4M" },
  { id: "a2", name: "Taylor Wren",     tags: "pop · narrative",      hue: 340, monthly: "32.1M" },
  { id: "a3", name: "Greenfield",      tags: "punk · pop-rock",      hue: 180, monthly: "4.7M" },
  { id: "a4", name: "Mein Lotta-Leben",tags: "hörbuch · kids",       hue: 50,  monthly: "210k" },
  { id: "a5", name: "Micah Posner",    tags: "folk · indie",         hue: 30,  monthly: "2.2M" },
  { id: "a6", name: "Anne-Karin Dern", tags: "score · cinematic",    hue: 280, monthly: "180k" },
  { id: "a7", name: "Carmen Sabra",    tags: "pop · femme",          hue: 320, monthly: "26.0M" },
  { id: "a8", name: "Die drei !!!",    tags: "hörspiel · kids",      hue: 200, monthly: "640k" },
];

const NOW_PLAYING = {
  title: "Space Oddity",
  subtitle: "2015 Remaster",
  artist: "Davis Bowmer",
  album: "Space Oddity (Remastered)",
  duration: 318, // seconds
  position: 168,
  hue: 215, pattern: "clouds",
  liked: false,
};

const QUEUE = [
  { ...NOW_PLAYING, idx: 1, current: true, cached: true },
  { idx: 2, title: "Adam's Song",                    artist: "Blynk-182",       duration: 249, cached: true,  liked: false, hue: 340, pattern: "portrait" },
  { idx: 3, title: "Coffee & TV",                    artist: "Blurr",           duration: 358, cached: true,  liked: true,  hue: 30,  pattern: "blob" },
  { idx: 4, title: "She",                            artist: "Greenfield",      duration: 134, cached: true,  liked: false, hue: 180, pattern: "clouds" },
  { idx: 5, title: "Polly — Live",                   artist: "Nirwana",         duration: 196, cached: true,  liked: false, hue: 0,   pattern: "halftone" },
  { idx: 6, title: "Reptilia",                       artist: "The Stripes",     duration: 219, cached: true,  liked: true,  hue: 50,  pattern: "split" },
  { idx: 7, title: "Changes — 2015 Remaster",        artist: "Davis Bowmer",    duration: 217, cached: true,  liked: false, hue: 215, pattern: "clouds" },
  { idx: 8, title: "Boys Don't Cry (Bestival Live)", artist: "The Cure-All",    duration: 185, cached: true,  liked: true,  hue: 260, pattern: "grain" },
  { idx: 9, title: "Beetlebum — 2012 Remaster",      artist: "Blurr",           duration: 305, cached: true,  liked: false, hue: 100, pattern: "split" },
  { idx: 10,title: "The Man Who Sold The World",     artist: "Nirwana",         duration: 227, cached: false, liked: false, hue: 0,   pattern: "portrait" },
  { idx: 11,title: "Love Will Tear Us Apart",        artist: "Joi Division",    duration: 208, cached: false, liked: true,  hue: 200, pattern: "halftone" },
  { idx: 12,title: "Stairway to Heaven",             artist: "Led Zeppolin",    duration: 482, cached: false, liked: true,  hue: 36,  pattern: "field" },
  { idx: 13,title: "Wonderwall — Acoustic",          artist: "Oase",            duration: 254, cached: false, liked: false, hue: 220, pattern: "tape" },
  { idx: 14,title: "Karma Police",                   artist: "Radiohead-ish",   duration: 263, cached: false, liked: true,  hue: 80,  pattern: "blob" },
];

const FAVORITES = [
  { idx: 1,  title: "King for a King",       artist: "Will Vallée",        duration: 246, hue: 80,  pattern: "field" },
  { idx: 2,  title: "Not That Simple",       artist: "Micah Posner",       duration: 234, hue: 28,  pattern: "blob" },
  { idx: 3,  title: "Shallow",               artist: "Lady Gala",          duration: 215, hue: 0,   pattern: "split" },
  { idx: 4,  title: "One Day At A Time",     artist: "Liam Mercer",        duration: 223, hue: 220, pattern: "stripes" },
  { idx: 5,  title: "Hijos Del Sol",         artist: "Hermanos Gutman",    duration: 176, hue: 24,  pattern: "field" },
  { idx: 6,  title: "I Took A Pill In Ibiza",artist: "Micah Posner",       duration: 280, hue: 28,  pattern: "blob" },
  { idx: 7,  title: "Fade Out Lines",        artist: "The Avener",         duration: 276, hue: 215, pattern: "halftone" },
  { idx: 8,  title: "Synergy",               artist: "Tash Sultan",        duration: 258, hue: 280, pattern: "halftone" },
  { idx: 9,  title: "Woman",                 artist: "Mumforde & Sons",    duration: 274, hue: 60,  pattern: "field" },
  { idx: 10, title: "Cannonball",            artist: "Damian Rye",         duration: 310, hue: 40,  pattern: "blob" },
  { idx: 11, title: "The Letter",            artist: "Xavier Reed",        duration: 251, hue: 100, pattern: "field" },
  { idx: 12, title: "Seize the Night",       artist: "Will Vallée",        duration: 259, hue: 80,  pattern: "field" },
  { idx: 13, title: "Basket Case",           artist: "Greenfield",         duration: 181, hue: 180, pattern: "clouds" },
];

const PLAYLISTS = [
  { id: "p1",  name: "Curated by Nudie Jeans 2001", desc: "What we listened to back in 2001.", curator: "Nudie Jeans Co", tracks: 41, duration: "2h 20m", hue: 28,  pattern: "tape", featured: true },
  { id: "p2",  name: "My top tracks playlist",      desc: "Heavy rotation, last 6 months.",     curator: "You",            tracks: 50, duration: "3h 12m", hue: 200, pattern: "grain" },
  { id: "p3",  name: "Texas Sun Radio",             desc: "Slow burn desert daydream.",         curator: "You",            tracks: 28, duration: "1h 48m", hue: 24,  pattern: "field" },
  { id: "p4",  name: "Fooobar",                     desc: "Friday-night kitchen disco.",        curator: "You",            tracks: 33, duration: "2h 06m", hue: 320, pattern: "blob" },
  { id: "p5",  name: "Test-Playlist 123",           desc: "Sandbox — don't judge.",             curator: "You",            tracks: 5,  duration: "18m",    hue: 0,   pattern: "split" },
  { id: "p6",  name: "Omas 70. Geburtstag",         desc: "Schunkeln & schmunzeln.",            curator: "You",            tracks: 22, duration: "1h 24m", hue: 50,  pattern: "stripes" },
  { id: "p7",  name: "Dancing In the Dark · Covers",desc: "Every Bruce, every angle.",          curator: "You",            tracks: 14, duration: "57m",    hue: 220, pattern: "halftone" },
  { id: "p8",  name: "So Long, Marianne",           desc: "Songs to write a long letter to.",   curator: "You",            tracks: 19, duration: "1h 12m", hue: 100, pattern: "portrait" },
  { id: "p9",  name: "Sauna",                       desc: "90° and a slow build.",              curator: "You",            tracks: 24, duration: "1h 36m", hue: 36,  pattern: "blob" },
  { id: "p10", name: "Frühstück",                   desc: "Crisp, bright, with butter.",        curator: "You",            tracks: 31, duration: "2h 04m", hue: 40,  pattern: "field" },
  { id: "p11", name: "All My Favorite Songs",       desc: "The shortlist of shortlists.",       curator: "You",            tracks: 88, duration: "5h 42m", hue: 180, pattern: "stripes" },
  { id: "p12", name: "Christmas Party",             desc: "Tannenbaum to turntable.",           curator: "You",            tracks: 42, duration: "2h 38m", hue: 0,   pattern: "halftone" },
];

const PLAYLIST_TRACKS = [
  { idx: 1, title: "Hate To Say I Told You So", artist: "The Hipes",                     duration: 200, plays: "84.2M", hue: 220, pattern: "stripes" },
  { idx: 2, title: "On Top Of Your World",      artist: "Sahara Hotnights",              duration: 196, plays: "1.1M",  hue: 30,  pattern: "blob" },
  { idx: 3, title: "The Band",                  artist: "Mando Dolo",                    duration: 195, plays: "2.4M",  hue: 200, pattern: "field" },
  { idx: 4, title: "Smash It Up",               artist: "The (International) Conspiracy",duration: 194, plays: "812k",  hue: 320, pattern: "halftone" },
  { idx: 5, title: "Over 'fore It Started",     artist: "Caesarea",                      duration: 170, plays: "440k",  hue: 50,  pattern: "tape" },
  { idx: 6, title: "By The Time…",              artist: "Lily of the Valley",            duration: 184, plays: "612k",  hue: 100, pattern: "split" },
  { idx: 7, title: "Refused Party Program",     artist: "Refused-ish",                   duration: 232, plays: "1.8M",  hue: 0,   pattern: "grain" },
];

const SEARCH_CHIPS = [
  { label: "Pop",        hue: 320 },
  { label: "Indie",      hue: 30  },
  { label: "Electronic", hue: 200 },
  { label: "Hip-hop",    hue: 12  },
  { label: "Folk",       hue: 80  },
  { label: "Jazz",       hue: 36  },
  { label: "Classical",  hue: 260 },
  { label: "Soundtrack", hue: 0   },
  { label: "Hörspiel",   hue: 220 },
  { label: "Lo-fi",      hue: 180 },
];

const RECENT_SEARCHES = [
  "liam mercer knebworth",
  "dookie green",
  "carmen sabra",
  "sauna playlist",
  "wonderwall acoustic",
];

const formatTime = (sec) => {
  if (sec == null) return "—";
  const m = Math.floor(sec / 60);
  const s = Math.floor(sec % 60);
  return `${m}:${s.toString().padStart(2, "0")}`;
};

const formatTimeLong = (sec) => {
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  return h > 0 ? `${h} hr ${m} min` : `${m} min`;
};

Object.assign(window, {
  COVERS, findCover, ARTISTS, NOW_PLAYING, QUEUE, FAVORITES,
  PLAYLISTS, PLAYLIST_TRACKS, SEARCH_CHIPS, RECENT_SEARCHES,
  formatTime, formatTimeLong,
});
