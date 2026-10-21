// Icon set — line-style, 1.5 stroke, currentColor.
// Each icon takes a `size` prop (default 18) and inherits color.

const I = ({ children, size = 18, stroke = 1.5, fill = "none", style }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill={fill} stroke="currentColor" strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round" style={style}>
    {children}
  </svg>
);

const Icons = {
  // brand mark — green app icon: paper plane + music notes (matches user's macOS app icon)
  Mark: ({ size = 28 }) => (
    <svg width={size} height={size} viewBox="0 0 64 64" fill="none" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <linearGradient id="splGrad" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stopColor="#2BC766"/>
          <stop offset="100%" stopColor="#0E7C38"/>
        </linearGradient>
      </defs>
      <rect x="2" y="2" width="60" height="60" rx="14" fill="url(#splGrad)"/>
      {/* paper plane */}
      <path d="M14 30 L50 16 L36 50 L30 36 Z" fill="#FFFFFF"/>
      <path d="M30 36 L50 16" stroke="#0E7C38" strokeWidth="1.6" strokeLinecap="round" opacity="0.7"/>
      <path d="M30 36 L36 50" stroke="#0E7C38" strokeWidth="1.6" strokeLinecap="round" opacity="0.4"/>
      {/* music notes */}
      <circle cx="16" cy="50" r="2.4" fill="#FFFFFF" opacity="0.9"/>
      <path d="M18 50 V42 L24 40 V48" stroke="#FFFFFF" strokeWidth="1.4" strokeLinecap="round" opacity="0.9" fill="none"/>
      <circle cx="22" cy="48" r="2.2" fill="#FFFFFF" opacity="0.9"/>
    </svg>
  ),
  // flat monochrome version of the plane glyph (for chips, watermarks)
  MarkLine: ({ size = 18 }) => (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <path d="M3 12 L21 4 L13 21 L11 13 L3 12 Z" fill="currentColor" stroke="none"/>
    </svg>
  ),
  Home: (p) => <I {...p}><path d="M3 11 L12 3 L21 11 V20 a1 1 0 0 1 -1 1 H15 V14 H9 V21 H4 a1 1 0 0 1 -1 -1 Z"/></I>,
  Search: (p) => <I {...p}><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></I>,
  Queue: (p) => <I {...p}><path d="M4 7h13"/><path d="M4 12h13"/><path d="M4 17h9"/><path d="M19 14v7"/><circle cx="17.5" cy="20.5" r="1.5"/></I>,
  Speaker: (p) => <I {...p}><rect x="6" y="3" width="12" height="18" rx="2"/><circle cx="12" cy="14" r="3.5"/><circle cx="12" cy="6.5" r="0.8" fill="currentColor"/></I>,
  Heart: (p) => <I {...p}><path d="M12 21s-7-4.5-9-9.5C1.5 7 4 4 7 4c1.8 0 3 .8 5 3 2-2.2 3.2-3 5-3 3 0 5.5 3 4 7.5C19 16.5 12 21 12 21Z"/></I>,
  HeartFilled: ({ size = 18, color = "currentColor" }) => (
    <svg width={size} height={size} viewBox="0 0 24 24" fill={color} stroke={color} strokeWidth="1.5" strokeLinejoin="round">
      <path d="M12 21s-7-4.5-9-9.5C1.5 7 4 4 7 4c1.8 0 3 .8 5 3 2-2.2 3.2-3 5-3 3 0 5.5 3 4 7.5C19 16.5 12 21 12 21Z"/>
    </svg>
  ),
  Playlist: (p) => <I {...p}><path d="M4 6h12"/><path d="M4 11h12"/><path d="M4 16h7"/><path d="M16 13v8"/><path d="M16 13 21 11"/></I>,
  Album: (p) => <I {...p}><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3"/><circle cx="12" cy="12" r="0.5" fill="currentColor"/></I>,
  Artist: (p) => <I {...p}><rect x="9" y="2" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0"/><path d="M12 18v3"/><path d="M9 21h6"/></I>,
  Settings: (p) => <I {...p}><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1Z"/></I>,
  Play: ({ size = 18 }) => (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor"><path d="M7 4.5v15a1 1 0 0 0 1.5.87l13-7.5a1 1 0 0 0 0-1.73l-13-7.5A1 1 0 0 0 7 4.5Z"/></svg>
  ),
  Pause: ({ size = 18 }) => (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="4" width="4.5" height="16" rx="1"/><rect x="13.5" y="4" width="4.5" height="16" rx="1"/></svg>
  ),
  Prev: ({ size = 18 }) => (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor"><path d="M6 4.5a1 1 0 0 1 2 0v6.7l9.5-6.6a1 1 0 0 1 1.5.83v13.14a1 1 0 0 1-1.5.83L8 12.8v6.7a1 1 0 0 1-2 0V4.5Z"/></svg>
  ),
  Next: ({ size = 18 }) => (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor"><path d="M18 4.5a1 1 0 0 0-2 0v6.7L6.5 4.6A1 1 0 0 0 5 5.43v13.14a1 1 0 0 0 1.5.83L16 12.8v6.7a1 1 0 0 0 2 0V4.5Z"/></svg>
  ),
  Shuffle: (p) => <I {...p}><path d="M16 3h5v5"/><path d="M4 20 21 3"/><path d="M21 16v5h-5"/><path d="M15 15l6 6"/><path d="M4 4l5 5"/></I>,
  Repeat: (p) => <I {...p}><path d="M17 2l4 4-4 4"/><path d="M3 11V9a4 4 0 0 1 4-4h14"/><path d="M7 22l-4-4 4-4"/><path d="M21 13v2a4 4 0 0 1-4 4H3"/></I>,
  Volume: (p) => <I {...p}><path d="M11 5 6 9H3v6h3l5 4Z"/><path d="M15.5 8.5a5 5 0 0 1 0 7"/><path d="M18.5 5.5a9 9 0 0 1 0 13"/></I>,
  More: (p) => <I {...p} stroke={0}><circle cx="6" cy="12" r="1.6" fill="currentColor"/><circle cx="12" cy="12" r="1.6" fill="currentColor"/><circle cx="18" cy="12" r="1.6" fill="currentColor"/></I>,
  ChevronLeft: (p) => <I {...p}><path d="m15 6-6 6 6 6"/></I>,
  ChevronRight: (p) => <I {...p}><path d="m9 6 6 6-6 6"/></I>,
  ChevronDown: (p) => <I {...p}><path d="m6 9 6 6 6-6"/></I>,
  Sidebar: (p) => <I {...p}><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16"/></I>,
  Refresh: (p) => <I {...p}><path d="M21 12a9 9 0 1 1-3-6.7"/><path d="M21 4v5h-5"/></I>,
  Download: (p) => <I {...p}><path d="M12 4v12"/><path d="m7 11 5 5 5-5"/><path d="M5 20h14"/></I>,
  Share: (p) => <I {...p}><circle cx="6" cy="12" r="2.5"/><circle cx="18" cy="6" r="2.5"/><circle cx="18" cy="18" r="2.5"/><path d="m8 11 8-4"/><path d="m8 13 8 4"/></I>,
  Plus: (p) => <I {...p}><path d="M12 5v14"/><path d="M5 12h14"/></I>,
  Minus: (p) => <I {...p}><path d="M5 12h14"/></I>,
  Cached: (p) => <I {...p}><path d="M21 12a9 9 0 1 1-3-6.7"/><path d="M21 4v5h-5"/><path d="m9 12 2 2 4-4"/></I>,
  Expand: (p) => <I {...p}><path d="M4 14v6h6"/><path d="M20 10V4h-6"/><path d="m4 20 7-7"/><path d="m20 4-7 7"/></I>,
  Minimize: (p) => <I {...p}><path d="M10 4H4v6"/><path d="M14 20h6v-6"/><path d="m4 4 7 7"/><path d="m20 20-7-7"/></I>,
  Drag: (p) => <I {...p} stroke={0}><circle cx="9" cy="6" r="1.4" fill="currentColor"/><circle cx="9" cy="12" r="1.4" fill="currentColor"/><circle cx="9" cy="18" r="1.4" fill="currentColor"/><circle cx="15" cy="6" r="1.4" fill="currentColor"/><circle cx="15" cy="12" r="1.4" fill="currentColor"/><circle cx="15" cy="18" r="1.4" fill="currentColor"/></I>,
  Computer: (p) => <I {...p}><rect x="2" y="4" width="20" height="12" rx="2"/><path d="M8 20h8"/><path d="M12 16v4"/></I>,
  Phone: (p) => <I {...p}><rect x="7" y="2" width="10" height="20" rx="2"/><path d="M11 18h2"/></I>,
  AirPlay: (p) => <I {...p}><path d="M6 17H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2h-2"/><path d="m12 14 5 7H7Z"/></I>,
  CheckCircle: ({ size = 16, color = "var(--accent)" }) => (
    <svg width={size} height={size} viewBox="0 0 24 24" fill={color}><path d="M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20Zm5 7.4-6.2 6.2a1 1 0 0 1-1.4 0L6.3 12.4a1 1 0 0 1 1.4-1.4l2.4 2.4L15.6 8a1 1 0 0 1 1.4 1.4Z"/></svg>
  ),
  Dot: ({ size = 4, color = "currentColor" }) => (
    <svg width={size} height={size} viewBox="0 0 4 4"><circle cx="2" cy="2" r="2" fill={color}/></svg>
  ),
  ArrowUpRight: (p) => <I {...p}><path d="M7 17 17 7"/><path d="M9 7h8v8"/></I>,
  Logout: (p) => <I {...p}><path d="M15 4h3a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-3"/><path d="M10 17l5-5-5-5"/><path d="M15 12H3"/></I>,
  Clock: (p) => <I {...p}><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></I>,
  Filter: (p) => <I {...p}><path d="M3 5h18"/><path d="M6 12h12"/><path d="M10 19h4"/></I>,
  X: (p) => <I {...p}><path d="m6 6 12 12"/><path d="m18 6-12 12"/></I>,
  Edit: (p) => <I {...p}><path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z"/></I>,
  Trash: (p) => <I {...p}><path d="M3 6h18"/><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/></I>,
  Live: ({ size = 8 }) => (
    <svg width={size} height={size} viewBox="0 0 8 8"><circle cx="4" cy="4" r="4" fill="#E84118"/></svg>
  ),
};

Object.assign(window, { Icons });
