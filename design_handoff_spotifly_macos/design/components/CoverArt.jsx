// CoverArt — deterministic SVG cover-art placeholders by hue + pattern key.
// Avoids copyrighted album art while staying expressive.

const CoverArt = ({ hue = 200, pattern = "stripes", size = 80, rounded = 6, title }) => {
  const bg  = `oklch(0.62 0.16 ${hue})`;
  const ink = `oklch(0.16 0.04 ${hue})`;
  const lt  = `oklch(0.94 0.04 ${hue})`;
  const md  = `oklch(0.78 0.12 ${hue})`;
  const acc = `oklch(0.50 0.18 ${(hue + 40) % 360})`;

  const renderPattern = () => {
    switch (pattern) {
      case "stripes":
        return (
          <g>
            {Array.from({ length: 7 }).map((_, i) => (
              <rect key={i} x={i * 12} y="0" width="6" height="80" fill={i % 2 ? lt : ink} opacity={0.85} />
            ))}
          </g>
        );
      case "blob":
        return (
          <g>
            <rect width="80" height="80" fill={bg}/>
            <circle cx="28" cy="46" r="28" fill={lt} opacity="0.85"/>
            <circle cx="56" cy="24" r="14" fill={acc}/>
          </g>
        );
      case "split":
        return (
          <g>
            <rect width="80" height="40" fill={ink}/>
            <rect y="40" width="80" height="40" fill={lt}/>
            <circle cx="40" cy="40" r="14" fill={acc}/>
          </g>
        );
      case "halftone":
        return (
          <g>
            <rect width="80" height="80" fill={bg}/>
            {Array.from({ length: 64 }).map((_, i) => {
              const x = (i % 8) * 10 + 5;
              const y = Math.floor(i / 8) * 10 + 5;
              const r = ((x + y) % 17) / 7 + 0.6;
              return <circle key={i} cx={x} cy={y} r={r} fill={ink} opacity={0.7}/>;
            })}
          </g>
        );
      case "clouds":
        return (
          <g>
            <rect width="80" height="80" fill={bg}/>
            <ellipse cx="20" cy="56" rx="22" ry="10" fill={lt} opacity="0.6"/>
            <ellipse cx="56" cy="48" rx="20" ry="9" fill={lt} opacity="0.8"/>
            <ellipse cx="34" cy="64" rx="26" ry="8" fill={md}/>
          </g>
        );
      case "portrait":
        return (
          <g>
            <rect width="80" height="80" fill={ink}/>
            <ellipse cx="40" cy="32" rx="14" ry="16" fill={md}/>
            <rect x="20" y="48" width="40" height="40" rx="16" fill={md}/>
            <rect x="0" y="68" width="80" height="12" fill={acc}/>
          </g>
        );
      case "tape":
        return (
          <g>
            <rect width="80" height="80" fill={bg}/>
            <rect x="6" y="22" width="68" height="40" rx="3" fill={lt}/>
            <circle cx="22" cy="42" r="6" fill={ink}/><circle cx="22" cy="42" r="2" fill={lt}/>
            <circle cx="58" cy="42" r="6" fill={ink}/><circle cx="58" cy="42" r="2" fill={lt}/>
            <rect x="30" y="50" width="20" height="6" fill={acc}/>
          </g>
        );
      case "field":
        return (
          <g>
            <rect width="80" height="50" fill={bg}/>
            <rect y="50" width="80" height="30" fill={ink}/>
            <circle cx="58" cy="20" r="9" fill={lt}/>
            <path d="M0 56 L20 50 L36 58 L56 52 L80 60 L80 80 L0 80 Z" fill={acc}/>
          </g>
        );
      case "grain":
      default:
        return (
          <g>
            <rect width="80" height="80" fill={bg}/>
            <rect x="0" y="0" width="80" height="80" fill={ink} opacity="0.15"/>
            <rect x="10" y="10" width="60" height="60" fill={lt} opacity="0.18"/>
          </g>
        );
    }
  };

  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 80 80"
      style={{
        borderRadius: rounded,
        display: "block",
        boxShadow: "0 1px 2px rgba(0,0,0,0.08), 0 4px 12px rgba(0,0,0,0.06)",
      }}
      aria-label={title}
    >
      <defs>
        <clipPath id={`cl-${hue}-${pattern}`}><rect width="80" height="80" rx={rounded * 80 / size}/></clipPath>
      </defs>
      <g clipPath={`url(#cl-${hue}-${pattern})`}>{renderPattern()}</g>
    </svg>
  );
};

// circular variant for artist avatars
const ArtistArt = ({ hue = 200, size = 56, name = "" }) => {
  const bg  = `oklch(0.72 0.14 ${hue})`;
  const ink = `oklch(0.20 0.04 ${hue})`;
  const lt  = `oklch(0.96 0.02 ${hue})`;
  const initials = name.split(" ").slice(0, 2).map(s => s[0]).join("").toUpperCase();
  return (
    <svg width={size} height={size} viewBox="0 0 80 80" style={{ borderRadius: "50%", display: "block" }}>
      <defs>
        <clipPath id={`ca-${hue}`}><circle cx="40" cy="40" r="40"/></clipPath>
      </defs>
      <g clipPath={`url(#ca-${hue})`}>
        <rect width="80" height="80" fill={bg}/>
        <ellipse cx="40" cy="34" rx="18" ry="20" fill={ink} opacity="0.85"/>
        <rect x="14" y="54" width="52" height="40" rx="20" fill={ink} opacity="0.85"/>
        <text x="40" y="48" textAnchor="middle" fontSize="22"
              fontFamily="Instrument Serif, serif" fill={lt}>{initials}</text>
      </g>
    </svg>
  );
};

Object.assign(window, { CoverArt, ArtistArt });
