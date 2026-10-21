// Native macOS control kit — each element carries data-sw = the SwiftUI control it maps to.
Object.assign(Icons, {
  Check: (p) => <svg width={p.size||14} height={p.size||14} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"><path d="m5 12.5 4.5 4.5L19 7"/></svg>,
  Copy: (p) => <svg width={p.size||14} height={p.size||14} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6"><rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/></svg>,
  ListPlus: (p) => <svg width={p.size||14} height={p.size||14} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"><path d="M4 6h12M4 11h12M4 16h7M17 14v6M14 17h6"/></svg>,
  Keyboard: (p) => <svg width={p.size||14} height={p.size||14} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"><rect x="2" y="6" width="20" height="12" rx="2"/><path d="M6 10h.01M10 10h.01M14 10h.01M18 10h.01M7 14h10"/></svg>,
  Sliders: (p) => <svg width={p.size||14} height={p.size||14} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"><path d="M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M20 18h0"/><circle cx="16" cy="6" r="2"/><circle cx="10" cy="12" r="2"/><circle cx="18" cy="18" r="2"/></svg>,
  User: (p) => <svg width={p.size||14} height={p.size||14} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6"><circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/></svg>,
  Info: (p) => <svg width={p.size||14} height={p.size||14} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"><circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7.5v.01"/></svg>,
  Inspector: (p) => <svg width={p.size||14} height={p.size||14} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M15 4v16"/></svg>,
  Lock: (p) => <svg width={p.size||14} height={p.size||14} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6"><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>,
});

const Btn = ({ kind = "bordered", lg, icon, iconOnly, children, sw, destructive, pressed, onClick, title, style, disabled }) => {
  const I = icon && Icons[icon];
  const map = { bordered: "Button · .bordered", prominent: "Button · .borderedProminent", borderless: "Button · .borderless", link: "Button · .link" };
  return (
    <button className={`nb nb-${kind}${lg ? " nb-lg" : ""}${iconOnly ? " nb-icon" : ""}${destructive ? " nb-destr" : ""}`}
      data-sw={sw || map[kind] + (destructive ? " (role: .destructive)" : "")} aria-pressed={pressed} onClick={onClick} title={title} style={style} disabled={disabled}>
      {I && <I size={iconOnly ? 15 : 13} />}{children}
    </button>
  );
};

const NToggle = ({ on, onChange }) => (
  <label className="ntog" data-sw="Toggle · .switch"><input type="checkbox" checked={!!on} onChange={(e) => onChange?.(e.target.checked)} /><span></span></label>
);

const NSeg = ({ value, options, onChange }) => (
  <div className="nseg" data-sw="Picker · .segmented">
    {options.map((o) => <button key={o.value} className={value === o.value ? "on" : ""} onClick={() => onChange?.(o.value)}>{o.label}</button>)}
  </div>
);

const NPopup = ({ value, options, onChange }) => (
  <span className="npop" data-sw="Picker · .menu">
    <select value={value} onChange={(e) => onChange?.(e.target.value)}>{options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}</select>
  </span>
);

const NSlider = ({ value, min = 0, max = 100, onChange, thin, style, sw }) => (
  <input type="range" className={"nsl" + (thin ? " thin" : "")} min={min} max={max} value={value} data-sw={sw || "Slider"}
    style={{ "--p": `${((value - min) / (max - min)) * 100}%`, ...style }} onChange={(e) => onChange?.(+e.target.value)} />
);

const NSearch = ({ value, onChange, placeholder = "Suchen", sw = ".searchable", width, autoFocus }) => (
  <div className="search" data-sw={sw} style={width ? { width } : null}>
    <Icons.Search size={13} />
    <input value={value} autoFocus={autoFocus} onChange={(e) => onChange(e.target.value)} placeholder={placeholder} />
    {value && <button onClick={() => onChange("")} style={{ display: "flex" }}><Icons.X size={12} /></button>}
  </div>
);

const NSection = ({ header, footer, children }) => (
  <section className="nsec" data-sw="Section">
    {header && <h4>{header}</h4>}
    <div className="nsec-box">{children}</div>
    {footer && <p className="nsec-foot">{footer}</p>}
  </section>
);

const NRow = ({ label, sub, children, icon, sw = "LabeledContent" }) => (
  <div className="nrow" data-sw={sw}>
    {icon}
    <div className="nrow-l">{label}{sub && <small>{sub}</small>}</div>
    <div className="nrow-v">{children}</div>
  </div>
);

const NUnavailable = ({ icon = "Info", title, children, actions }) => {
  const I = Icons[icon];
  return (
    <div className="cuv" data-sw="ContentUnavailableView">
      <I size={40} /><b>{title}</b><div style={{ maxWidth: 380 }}>{children}</div>
      {actions && <div style={{ display: "flex", gap: 8, marginTop: 10 }}>{actions}</div>}
    </div>
  );
};

// Menu — click opens a native-looking pull-down. items: [{label, icon, onClick, destructive} | "-"]
const NMenu = ({ items, icon = "More", kind = "borderless", label, sw = "Menu", className }) => {
  const [open, setOpen] = React.useState(null);
  React.useEffect(() => {
    if (!open) return;
    const close = () => setOpen(null);
    window.addEventListener("mousedown", close);
    return () => window.removeEventListener("mousedown", close);
  }, [open]);
  const I = Icons[icon];
  return (
    <>
      <button className={`nb nb-${kind}${label ? "" : " nb-icon"} ${className || ""}`} data-sw={sw}
        onClick={(e) => { e.stopPropagation(); const r = e.currentTarget.getBoundingClientRect(); setOpen({ x: Math.min(r.left, window.innerWidth - 240), y: r.bottom + 4 }); }}>
        {I && <I size={15} />}{label}
      </button>
      {open && ReactDOM.createPortal(
        <div className="nmenu" style={{ left: open.x, top: open.y, position: "fixed" }} onMouseDown={(e) => e.stopPropagation()}>
          {items.map((it, i) => it === "-" ? <hr key={i} /> : (
            <button key={i} className={it.destructive ? "destr" : ""} onClick={() => { it.onClick?.(); setOpen(null); }}>
              <span style={{ width: 14, display: "flex" }}>{it.icon && React.createElement(Icons[it.icon], { size: 13 })}</span>{it.label}
            </button>
          ))}
        </div>, document.body)}
    </>
  );
};

// standard track context actions — every item maps to an available Web API call
const trackMenu = (liked) => [
  { label: "Als Nächstes spielen", icon: "Next" },
  { label: "Zur Warteschlange hinzufügen", icon: "ListPlus" },
  "-",
  { label: liked ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen", icon: "Heart" },
  { label: "Zu Playlist hinzufügen …", icon: "Plus" },
  "-",
  { label: "Zum Album", icon: "Album" },
  { label: "Zum Künstler", icon: "Artist" },
  "-",
  { label: "Link kopieren", icon: "Copy" },
];

const HeartBtn = ({ on, onClick, keep }) => (
  <button className={"nb nb-borderless nb-icon rowact" + (on || keep ? " keep" : "")} data-sw="Button · .borderless (Toggle)" onClick={(e) => { e.stopPropagation(); onClick?.(); }} style={{ color: on ? "var(--red)" : "var(--l2)" }}>
    {on ? <Icons.HeartFilled size={14} color="var(--red)" /> : <Icons.Heart size={14} />}
  </button>
);

const Dot = () => <span className="ter" style={{ margin: "0 5px" }}>·</span>;

Object.assign(window, { Btn, NToggle, NSeg, NPopup, NSlider, NSearch, NSection, NRow, NUnavailable, NMenu, trackMenu, HeartBtn, Dot });
