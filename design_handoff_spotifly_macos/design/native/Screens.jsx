// Screens — Home, Search, Queue, Speakers, Profile

const TrackTable = ({ rows, currentIdx, onPlay, onLike, cols = ["num", "title", "album", "dur"], sortable, numKey = "idx", showCache, liked }) => {
  const [sort, setSort] = React.useState(null);
  const [sel, setSel] = React.useState(null);
  const sorted = React.useMemo(() => {
    if (!sort) return rows;
    const k = sort.key, d = sort.dir;
    return [...rows].sort((a, b) => (a[k] > b[k] ? 1 : a[k] < b[k] ? -1 : 0) * d);
  }, [rows, sort]);
  const H = ({ k, label, cls, sKey }) => (
    <th className={cls + (sortable && sKey ? " sortable" : "") + (sort?.key === sKey ? " sorted" : "")}
      onClick={() => sortable && sKey && setSort((s) => (s?.key === sKey ? { key: sKey, dir: -s.dir } : { key: sKey, dir: 1 }))}>
      {label}{sort?.key === sKey ? (sort.dir > 0 ? " ▲" : " ▼") : ""}
    </th>
  );
  return (
    <table className="ntab" data-sw={sortable ? "Table (sortOrder:) · .contextMenu" : "Table · .contextMenu"}>
      <thead><tr>
        {cols.includes("num") && <H label="#" cls="num" sKey={sortable ? numKey : null} />}
        <H label="Titel" cls="" sKey="title" />
        {cols.includes("album") && <H label="Album" cls="" sKey="albumName" />}
        {cols.includes("added") && <H label="Hinzugefügt" cls="" sKey="addedSort" />}
        <H label="Dauer" cls="dur" sKey="duration" />
        <th className="act"></th>
      </tr></thead>
      <tbody>
        {sorted.map((t) => {
          const now = t.idx === currentIdx;
          return (
            <tr key={t.idx} className={(sel === t.idx ? "sel " : "") + (now ? "now" : "")} onClick={() => setSel(t.idx)} onDoubleClick={() => onPlay?.(t.idx)}>
              {cols.includes("num") && <td className="num mono">{now ? <span className="eq"><i></i><i></i><i></i></span> : t[numKey]}</td>}
              <td>
                <div style={{ display: "flex", alignItems: "center", gap: 10, minWidth: 0 }}>
                  {t.hue != null && <CoverArt hue={t.hue} pattern={t.pattern} size={32} rounded={4} />}
                  <div style={{ minWidth: 0, lineHeight: 1.25 }}>
                    <div className="trunc" style={{ display: "flex", alignItems: "center" }}><span className="trunc">{t.title}</span>{showCache && t.cached && <span className="tagC" title="Im Offline-Cache">C</span>}</div>
                    {t.artist && <div className="trunc sec t-sub">{t.artist}</div>}
                  </div>
                </div>
              </td>
              {cols.includes("album") && <td className="sec trunc" style={{ maxWidth: 220 }}>{t.albumName}</td>}
              {cols.includes("added") && <td className="sec">{t.added}</td>}
              <td className="dur mono">{formatTime(t.duration)}</td>
              <td className="act">
                <HeartBtn on={liked || t.liked} onClick={() => onLike?.(t.idx)} />
                <span className="rowact"><NMenu items={trackMenu(liked || t.liked)} /></span>
              </td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
};

const SectHead = ({ title, children }) => (
  <div className="secthead"><span className="t-title2">{title}</span><div style={{ display: "flex", gap: 8, alignItems: "center" }}>{children}</div></div>
);

const MediaCard = ({ c, sub, onClick, w = 150, round }) => (
  <button className="card" style={{ width: w, alignItems: round ? "center" : "flex-start", textAlign: round ? "center" : "left" }} onClick={onClick} data-sw="Button · .plain (Karte)">
    {round ? <ArtistArt hue={c.hue} size={w} name={c.name} /> : <CoverArt hue={c.hue} pattern={c.pattern} size={w} rounded={8} />}
    <div style={{ width: "100%", lineHeight: 1.3 }}><div className="trunc t-head">{c.title || c.name}</div>{sub && <div className="trunc sec t-sub">{sub}</div>}</div>
  </button>
);

// ---------- HOME
const NHome = ({ tb, onNavigate, onJumpTo }) => {
  const [range, setRange] = React.useState("medium");
  const recent = [COVERS[0], COVERS[5], COVERS[1], COVERS[2], COVERS[3], COVERS[4], COVERS[6], COVERS[7], COVERS[8]];
  const top = range === "short" ? QUEUE.slice(3, 9) : range === "long" ? QUEUE.slice(8, 14) : QUEUE.slice(1, 7);
  return (
    <>
      <NToolbar {...tb} title="Startseite" trailing={<TbBtn icon="Refresh" title="Aktualisieren (⌘R)" />} />
      <div className="content">
        <SectHead title="Zuletzt gehört" />
        <div className="hrow" data-sw="ScrollView(.horizontal) · LazyHStack">
          {recent.map((c) => <MediaCard key={c.id} c={c} sub={c.artist} onClick={() => onNavigate("albums")} />)}
        </div>
        <SectHead title="Deine Top-Titel"><NSeg value={range} onChange={setRange} options={[{ value: "short", label: "4 Wochen" }, { value: "medium", label: "6 Monate" }, { value: "long", label: "1 Jahr" }]} /></SectHead>
        <div style={{ padding: "0 28px", display: "grid", gridTemplateColumns: "repeat(auto-fill,minmax(260px,1fr))", gap: "2px 16px" }} data-sw="LazyVGrid">
          {top.map((t, i) => (
            <button key={t.idx} className="nli" onDoubleClick={() => onJumpTo(t.idx)} style={{ borderBottom: ".5px solid var(--sep)", borderRadius: 0 }}>
              <span className="sec mono" style={{ width: 16, textAlign: "right" }}>{i + 1}</span>
              <CoverArt hue={t.hue} pattern={t.pattern} size={36} rounded={4} />
              <div style={{ minWidth: 0, flex: 1, lineHeight: 1.25 }}><div className="trunc">{t.title}</div><div className="trunc sec t-sub">{t.artist}</div></div>
            </button>
          ))}
        </div>
        <SectHead title="Deine Top-Künstler" />
        <div className="hrow" data-sw="ScrollView(.horizontal) · LazyHStack">
          {ARTISTS.map((a) => <MediaCard key={a.id} c={a} round w={130} onClick={() => onNavigate("artists")} />)}
        </div>
        <SectHead title="Deine Playlists"><Btn kind="link" onClick={() => onNavigate("playlists")}>Alle anzeigen</Btn></SectHead>
        <div className="hrow" data-sw="ScrollView(.horizontal) · LazyHStack">
          {PLAYLISTS.slice(0, 9).map((p) => <MediaCard key={p.id} c={{ ...p, title: p.name }} sub={p.curator === "You" ? `${p.tracks} Titel` : `von ${p.curator}`} onClick={() => onNavigate("playlists")} />)}
        </div>
      </div>
    </>
  );
};

// ---------- SEARCH
const NSearchScreen = ({ tb, onNavigate, onJumpTo }) => {
  const [q, setQ] = React.useState("");
  const [scope, setScope] = React.useState("all");
  const [recent, setRecent] = React.useState(RECENT_SEARCHES);
  const lq = q.toLowerCase();
  const tr = QUEUE.filter((t) => (t.title + t.artist).toLowerCase().includes(lq));
  const ar = ARTISTS.filter((a) => a.name.toLowerCase().includes(lq));
  const al = COVERS.filter((c) => (c.title + c.artist).toLowerCase().includes(lq));
  const pl = PLAYLISTS.filter((p) => p.name.toLowerCase().includes(lq));
  const show = (k) => scope === "all" || scope === k;
  const lim = scope === "all" ? 5 : 10;
  const none = !tr.length && !ar.length && !al.length && !pl.length;
  return (
    <>
      <NToolbar {...tb} title="Suchen" trailing={<NSearch value={q} onChange={setQ} placeholder="Songs, Künstler, Alben, Podcasts" width={300} autoFocus sw=".searchable(placement: .toolbar)" />} />
      <div className="content">
        {!q && <div className="nform" style={{ paddingTop: 12 }}>
          {recent.length ? <NSection header="Letzte Suchen" footer="Wird nur auf diesem Mac gespeichert.">
            {recent.map((r) => <NRow key={r} sw="List · Button" label={<button style={{ width: "100%", textAlign: "left" }} onClick={() => setQ(r)}>{r}</button>}><Btn kind="borderless" iconOnly icon="X" onClick={() => setRecent(recent.filter((x) => x !== r))} /></NRow>)}
          </NSection> : <NUnavailable icon="Search" title="Keine letzten Suchen">Suche nach Songs, Künstlern, Alben, Playlists und Podcasts.</NUnavailable>}
          {recent.length > 0 && <div style={{ textAlign: "right" }}><Btn onClick={() => setRecent([])}>Verlauf löschen</Btn></div>}
        </div>}
        {q && <>
          <div style={{ padding: "4px 28px 8px" }} data-sw=".searchScopes">
            <NSeg value={scope} onChange={setScope} options={[{ value: "all", label: "Alle" }, { value: "track", label: "Songs" }, { value: "artist", label: "Künstler" }, { value: "album", label: "Alben" }, { value: "playlist", label: "Playlists" }, { value: "show", label: "Podcasts" }]} />
          </div>
          {none || scope === "show" ? <NUnavailable icon="Search" title={`Keine Ergebnisse für „${q}“`}>Prüfe die Schreibweise oder versuche einen anderen Begriff.</NUnavailable> : <>
            {show("track") && tr.length > 0 && <><SectHead title="Songs" /><div style={{ padding: "0 20px" }}><TrackTable rows={tr.slice(0, lim)} onPlay={onJumpTo} cols={["title", "dur"]} /></div></>}
            {show("artist") && ar.length > 0 && <><SectHead title="Künstler" /><div className="hrow">{ar.slice(0, lim).map((a) => <MediaCard key={a.id} c={a} round w={120} sub="Künstler" onClick={() => onNavigate("artists")} />)}</div></>}
            {show("album") && al.length > 0 && <><SectHead title="Alben" /><div className="hrow">{al.slice(0, lim).map((c) => <MediaCard key={c.id} c={c} sub={`${c.year} · ${c.artist}`} w={140} onClick={() => onNavigate("albums")} />)}</div></>}
            {show("playlist") && pl.length > 0 && <><SectHead title="Playlists" /><div className="hrow">{pl.slice(0, lim).map((p) => <MediaCard key={p.id} c={{ ...p, title: p.name }} sub={`von ${p.curator === "You" ? "dir" : p.curator}`} w={140} onClick={() => onNavigate("playlists")} />)}</div></>}
            {scope !== "all" && <div style={{ textAlign: "center", padding: 20 }}><Btn>Mehr laden</Btn></div>}
          </>}
        </>}
      </div>
    </>
  );
};

// ---------- QUEUE
const NQueue = ({ tb, tracks, currentIdx, onJumpTo, onToggleLike }) => {
  const remaining = tracks.filter((t) => t.idx > currentIdx).length;
  const cached = tracks.filter((t) => t.cached).length;
  const rows = tracks.map((t) => ({ ...t, albumName: t.idx === 1 ? NOW_PLAYING.album : "" }));
  return (
    <>
      <NToolbar {...tb} title="Warteschlange" trailing={<><TbBtn icon="Refresh" title="Aktualisieren" /><TbBtn icon="Download" title="Alle in den Offline-Cache laden" /></>} />
      <div className="content">
        <div className="pad" style={{ display: "flex", alignItems: "flex-end", justifyContent: "space-between", paddingBottom: 12 }}>
          <div><div className="t-large">Warteschlange</div><div className="sec"><span className="nowrap">{tracks.length} Titel</span><Dot /><span className="nowrap">{remaining} ausstehend</span><Dot /><span className="nowrap">{cached} im Cache</span></div></div>
        </div>
        <div style={{ padding: "0 20px" }}>
          <TrackTable rows={rows} currentIdx={currentIdx} onPlay={onJumpTo} onLike={onToggleLike} cols={["num", "title", "dur"]} showCache />
        </div>
      </div>
    </>
  );
};

// ---------- SPEAKERS
const NSpeakers = ({ tb }) => {
  const [active, setActive] = React.useState("mac");
  const [vol, setVol] = React.useState({ mac: 80, iphone: 60, sonos: 42 });
  const [details, setDetails] = React.useState(false);
  const devs = [
    { id: "mac", name: "Spotifly", type: "Dieser Mac", icon: "Computer" },
    { id: "iphone", name: "iPhone von Ralph", type: "Smartphone", icon: "Phone" },
    { id: "sonos", name: "Wohnzimmer", type: "Lautsprecher", icon: "Speaker" },
  ];
  return (
    <>
      <NToolbar {...tb} title="Wiedergabe auf" trailing={<TbBtn icon="Refresh" title="Geräte suchen" />} />
      <div className="content" style={{ paddingTop: 8 }}>
        <div className="nform">
          <NSection header="Spotify Connect" footer="Zeigt alle Geräte, die gerade mit deinem Konto verbunden sind.">
            {devs.map((d) => { const I = Icons[d.icon]; const on = active === d.id; return (
              <div key={d.id}>
                <NRow sw="List · Button" icon={<span style={{ width: 28, height: 28, borderRadius: 7, background: on ? "var(--accent)" : "var(--fill)", color: on ? "#fff" : "var(--l1)", display: "flex", alignItems: "center", justifyContent: "center" }}><I size={15} /></span>}
                  label={<button style={{ width: "100%", textAlign: "left" }} onClick={() => setActive(d.id)}>{d.name}<small className="sec" style={{ display: "block", fontSize: 11 }}>{d.type}{on ? " · Aktiv" : ""}</small></button>}>
                  {on && <span style={{ color: "var(--accent)", display: "flex" }}><Icons.Check size={15} /></span>}
                </NRow>
                {on && <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "0 0 10px 44px" }}><Icons.Volume size={13} /><NSlider value={vol[d.id]} onChange={(v) => setVol({ ...vol, [d.id]: v })} style={{ flex: 1 }} sw="Slider (Gerätelautstärke)" /><span className="sec mono t-sub" style={{ width: 30 }}>{vol[d.id]} %</span></div>}
              </div>); })}
          </NSection>
          <NSection header="AirPlay" footer="Wählt einen AirPlay-Empfänger für die Ausgabe dieses Macs. Erfordert Zugriff auf das lokale Netzwerk.">
            <NRow label="Ausgabegerät" sub="MacBook Pro-Lautsprecher">
              <button className="nb nb-bordered" data-sw="AVRoutePickerView (AVKit, via NSViewRepresentable)"><Icons.AirPlay size={13} />Auswählen …</button>
            </NRow>
          </NSection>
          <NSection header="Verbindung">
            <NRow label="Status" icon={<span style={{ width: 8, height: 8, borderRadius: 4, background: "#34C759" }}></span>}>Verbunden seit 2 Std. 14 Min.</NRow>
            <div className="nrow" data-sw="DisclosureGroup" style={{ flexDirection: "column", alignItems: "stretch", gap: 0 }}>
              <button style={{ display: "flex", alignItems: "center", gap: 6, height: 24 }} onClick={() => setDetails(!details)}>
                <span style={{ display: "flex", transform: details ? "rotate(90deg)" : "none", transition: "transform .15s" }}><Icons.ChevronRight size={12} /></span>Details
              </button>
              {details && <div style={{ padding: "4px 0 2px 18px" }}>
                {[["Sitzung", "Aktiv"], ["Steuerkanal", "Bereit"], ["Audioausgabe", "CoreAudio · 44,1 kHz"], ["Stream", "Ogg Vorbis · 320 kbit/s"], ["Geräte-ID", "spotifly_7945"]].map(([l, v]) => <NRow key={l} label={l}><span className="mono" style={{ userSelect: "text" }}>{v}</span></NRow>)}
              </div>}
            </div>
            <NRow label="Neu verbinden" sub="Nur nötig, wenn die Wiedergabe hängt."><Btn>Neu verbinden</Btn></NRow>
          </NSection>
        </div>
      </div>
    </>
  );
};

// ---------- PROFILE
const NProfile = ({ tb, onSettings }) => (
  <>
    <NToolbar {...tb} title="Profil" />
    <div className="content" style={{ paddingTop: 24 }}>
      <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 10, marginBottom: 22 }}>
        <span data-sw="AsyncImage · .clipShape(Circle())" style={{ width: 96, height: 96, borderRadius: "50%", background: "linear-gradient(135deg,#F4C57E,#E89A6E)", color: "#5C3B1E", fontSize: 34, fontWeight: 700, display: "flex", alignItems: "center", justifyContent: "center" }}>RJ</span>
        <div className="t-title">llralphj</div>
      </div>
      <div className="nform">
        <NSection header="Konto">
          <NRow label="Anzeigename">llralphj</NRow>
          <NRow label="Benutzer-ID" sw="LabeledContent · .textSelection(.enabled)"><span className="mono" style={{ userSelect: "text" }}>qixixbr0ox6sik6jc6bkv6y6y</span><Btn kind="borderless" iconOnly icon="Copy" title="Kopieren" /></NRow>
          <NRow label="Profil im Web"><a href="#" data-sw="Link">open.spotify.com/user/…</a></NRow>
        </NSection>
        <NSection footer="Abo, Zahlungsdaten und Datenschutz verwaltest du in deinem Spotify-Konto.">
          <NRow label="Konto verwalten"><Btn icon="ArrowUpRight" sw="Link · .buttonStyle(.bordered)">In Spotify öffnen</Btn></NRow>
          <NRow label="App-Einstellungen"><Btn onClick={onSettings} sw="SettingsLink">Einstellungen …</Btn></NRow>
        </NSection>
        <div style={{ display: "flex", justifyContent: "center" }}><Btn destructive>Abmelden …</Btn></div>
      </div>
    </div>
  </>
);

Object.assign(window, { TrackTable, SectHead, MediaCard, NHome, NSearchScreen, NQueue, NSpeakers, NProfile });
