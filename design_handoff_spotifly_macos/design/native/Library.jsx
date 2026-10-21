// Library — Favorites (Table) + three-column NavigationSplitView for Playlists / Albums / Artists

const ADDED = ["12. Mai 2026", "3. Mai 2026", "28. Apr. 2026", "19. Apr. 2026", "2. Apr. 2026", "21. März 2026", "9. März 2026", "14. Feb. 2026", "1. Feb. 2026", "11. Jan. 2026", "30. Dez. 2025", "4. Dez. 2025", "18. Nov. 2025"];

const DetailHeader = ({ art, kind, title, children, actions }) => (
  <div className="dhead">
    <span data-sw="AsyncImage">{art}</span>
    <div style={{ minWidth: 0, flex: 1 }}>
      <div className="sec t-sub" style={{ fontWeight: 600 }}>{kind}</div>
      <div className="t-large" style={{ margin: "2px 0 4px", fontSize: 30 }}>{title}</div>
      <div className="sec">{children}</div>
      <div style={{ display: "flex", gap: 8, marginTop: 12, flexWrap: "wrap" }}>{actions}</div>
    </div>
  </div>
);

const NFavorites = ({ tb, tracks, onJumpTo, onToggleLike }) => {
  const [q, setQ] = React.useState("");
  const total = tracks.reduce((s, t) => s + t.duration, 0);
  const rows = tracks.map((t, i) => ({ ...t, added: ADDED[i] || "", addedSort: -i, albumName: (COVERS.find((c) => c.artist === t.artist) || {}).title || "Single" }))
    .filter((t) => (t.title + t.artist).toLowerCase().includes(q.toLowerCase()));
  return (
    <>
      <NToolbar {...tb} title="Favoriten" trailing={<><TbBtn icon="Refresh" title="Aktualisieren" /><NSearch value={q} onChange={setQ} placeholder="In Favoriten suchen" /></>} />
      <div className="content">
        <DetailHeader kind="Playlist" title="Favoriten"
          art={<div style={{ width: 132, height: 132, borderRadius: 10, background: "linear-gradient(135deg,#FF8FA3,#E0245E)", display: "flex", alignItems: "center", justifyContent: "center" }}><Icons.HeartFilled size={54} color="#fff" /></div>}
          actions={<><Btn kind="prominent" lg icon="Play">Abspielen</Btn><Btn lg icon="Shuffle">Zufällig</Btn></>}>
          {tracks.length} Titel<Dot />{formatTimeLong(total)}
        </DetailHeader>
        <div style={{ padding: "0 20px" }}>
          <TrackTable rows={rows} onPlay={onJumpTo} onLike={onToggleLike} liked sortable cols={["num", "title", "album", "added", "dur"]} />
        </div>
      </div>
    </>
  );
};

const SplitList = ({ items, sel, onSel, render, q, setQ, placeholder }) => (
  <div className="splitlist" style={{ flexShrink: 0, borderRight: ".5px solid var(--sep)", display: "flex", flexDirection: "column", minHeight: 0 }} data-sw="NavigationSplitView · content column · List(selection:)">
    <div style={{ padding: "4px 12px 6px" }}><NSearch value={q} onChange={setQ} placeholder={placeholder} width="100%" /></div>
    <div className="nlist" style={{ flex: 1, overflow: "auto", paddingBottom: 100 }}>
      {items.length ? items.map((it) => <button key={it.id} className={"nli" + (sel.id === it.id ? " on" : "")} onClick={() => onSel(it)}>{render(it)}</button>)
        : <NUnavailable icon="Search" title="Keine Treffer" />}
    </div>
  </div>
);

const ItemText = ({ a, b }) => <div style={{ minWidth: 0, flex: 1, lineHeight: 1.25 }}><div className="trunc">{a}</div>{b && <div className="trunc sec t-sub">{b}</div>}</div>;

// ---------- PLAYLISTS
const NPlaylists = ({ tb, onJumpTo }) => {
  const [sel, setSel] = React.useState(PLAYLISTS[1]);
  const [q, setQ] = React.useState("");
  const [followed, setFollowed] = React.useState(true);
  const own = sel.curator === "You";
  const items = PLAYLISTS.filter((p) => p.name.toLowerCase().includes(q.toLowerCase()));
  return (
    <>
      <NToolbar {...tb} title="Playlists" leading={<TbBtn icon="Plus" title="Neue Playlist" />}
        trailing={<><div className="glassgrp"><button className="tbi" data-sw="ShareLink"><Icons.Share size={15} /></button></div>
          <div className="glassgrp"><NMenu sw="ToolbarItem · Menu" items={[{ label: "Abspielen", icon: "Play" }, { label: "Zur Warteschlange hinzufügen", icon: "ListPlus" }, "-", ...(own ? [{ label: "Details bearbeiten …", icon: "Edit" }, { label: "Playlist löschen …", icon: "Trash", destructive: true }] : [{ label: followed ? "Aus Bibliothek entfernen" : "Zur Bibliothek hinzufügen", icon: "Heart" }]), "-", { label: "Link kopieren", icon: "Copy" }]} /></div></>} />
      <div style={{ flex: 1, minHeight: 0, display: "flex" }}>
        <SplitList items={items} sel={sel} onSel={setSel} q={q} setQ={setQ} placeholder="Playlists filtern"
          render={(p) => <><CoverArt hue={p.hue} pattern={p.pattern} size={36} rounded={4} /><ItemText a={p.name} b={p.curator === "You" ? `${p.tracks} Titel` : `von ${p.curator}`} /></>} />
        <div className="content detail" style={{ flex: 1, minWidth: 0 }} data-sw="NavigationSplitView · detail">
          <DetailHeader kind={own ? "Playlist" : "Playlist · Gefolgt"} title={sel.name} art={<CoverArt hue={sel.hue} pattern={sel.pattern} size={132} rounded={10} />}
            actions={<><Btn kind="prominent" lg icon="Play">Abspielen</Btn><Btn lg icon="Shuffle">Zufällig</Btn>
              {!own && <Btn lg icon={followed ? "Check" : "Plus"} onClick={() => setFollowed(!followed)} sw="Button · .bordered (Toggle)">{followed ? "In Bibliothek" : "Zur Bibliothek"}</Btn>}</>}>
            {sel.desc && <div style={{ marginBottom: 2 }}>{sel.desc}</div>}
            von {own ? "llralphj" : sel.curator}<Dot />{sel.tracks} Titel{own && <><Dot />{sel.duration}</>}
          </DetailHeader>
          <div style={{ padding: "0 20px" }}>
            {own ? <TrackTable rows={PLAYLIST_TRACKS.map((t) => ({ ...t, albumName: "" }))} onPlay={onJumpTo} cols={["num", "title", "dur"]} sortable />
              : <NUnavailable icon="Lock" title="Titelliste nicht verfügbar" actions={<Btn icon="ArrowUpRight">In Spotify öffnen</Btn>}>
                  Spotify gibt die Titel nur für eigene oder gemeinsame Playlists frei. Abspielen funktioniert trotzdem.
                </NUnavailable>}
          </div>
        </div>
      </div>
    </>
  );
};

// ---------- ALBUMS
const ALBUM_TRACKS = [["Burnout", 127], ["Having a Blast", 164], ["Chump", 173], ["Longview", 238], ["Welcome to Paradise", 224], ["Pulling Teeth", 150], ["Basket Case", 181], ["She", 134]];
const NAlbums = ({ tb, onJumpTo }) => {
  const [sel, setSel] = React.useState(COVERS[5]);
  const [q, setQ] = React.useState("");
  const [saved, setSaved] = React.useState(true);
  const [sort, setSort] = React.useState("added");
  let items = COVERS.filter((c) => (c.title + c.artist).toLowerCase().includes(q.toLowerCase()));
  if (sort === "title") items = [...items].sort((a, b) => a.title.localeCompare(b.title));
  if (sort === "artist") items = [...items].sort((a, b) => a.artist.localeCompare(b.artist));
  const rows = ALBUM_TRACKS.map(([title, duration], i) => ({ idx: i + 1, title, duration }));
  const total = rows.reduce((s, t) => s + t.duration, 0);
  return (
    <>
      <NToolbar {...tb} title="Alben" leading={<span data-sw="ToolbarItem · Picker(.menu)"><NPopup value={sort} onChange={setSort} options={[{ value: "added", label: "Zuletzt hinzugefügt" }, { value: "title", label: "Titel" }, { value: "artist", label: "Künstler" }]} /></span>}
        trailing={<><div className="glassgrp"><button className="tbi" data-sw="ShareLink"><Icons.Share size={15} /></button></div>
          <div className="glassgrp"><NMenu sw="ToolbarItem · Menu" items={[{ label: "Abspielen", icon: "Play" }, { label: "Zur Warteschlange hinzufügen", icon: "ListPlus" }, { label: "Zu Playlist hinzufügen …", icon: "Plus" }, "-", { label: "Zum Künstler", icon: "Artist" }, { label: "Link kopieren", icon: "Copy" }]} /></div></>} />
      <div style={{ flex: 1, minHeight: 0, display: "flex" }}>
        <SplitList items={items} sel={sel} onSel={setSel} q={q} setQ={setQ} placeholder="Alben filtern"
          render={(c) => <><CoverArt hue={c.hue} pattern={c.pattern} size={36} rounded={4} /><ItemText a={c.title} b={c.artist} /></>} />
        <div className="content detail" style={{ flex: 1, minWidth: 0 }} data-sw="NavigationSplitView · detail">
          <DetailHeader kind={`Album · ${sel.year}`} title={sel.title} art={<CoverArt hue={sel.hue} pattern={sel.pattern} size={132} rounded={10} />}
            actions={<><Btn kind="prominent" lg icon="Play">Abspielen</Btn><Btn lg icon="Shuffle">Zufällig</Btn>
              <Btn lg icon={saved ? "Check" : "Plus"} onClick={() => setSaved(!saved)} sw="Button · .bordered (Toggle)">{saved ? "In Bibliothek" : "Zur Bibliothek"}</Btn></>}>
            <a href="#" style={{ fontWeight: 600 }}>{sel.artist}</a><Dot />{sel.tracks} Titel<Dot />{formatTimeLong(total)}
          </DetailHeader>
          <div style={{ padding: "0 20px" }}><TrackTable rows={rows} onPlay={onJumpTo} cols={["num", "title", "dur"]} /></div>
        </div>
      </div>
    </>
  );
};

// ---------- ARTISTS
const NArtists = ({ tb }) => {
  const [sel, setSel] = React.useState(ARTISTS[0]);
  const [q, setQ] = React.useState("");
  const [following, setFollowing] = React.useState(true);
  const [group, setGroup] = React.useState("album");
  const items = ARTISTS.filter((a) => a.name.toLowerCase().includes(q.toLowerCase()));
  const disc = group === "album" ? COVERS.slice(0, 5) : group === "single" ? COVERS.slice(9, 12) : COVERS.slice(12, 14);
  return (
    <>
      <NToolbar {...tb} title="Künstler"
        trailing={<><div className="glassgrp"><button className="tbi" data-sw="ShareLink"><Icons.Share size={15} /></button></div>
          <div className="glassgrp"><NMenu sw="ToolbarItem · Menu" items={[{ label: "Abspielen", icon: "Play" }, { label: following ? "Nicht mehr folgen" : "Folgen", icon: "User" }, "-", { label: "Link kopieren", icon: "Copy" }]} /></div></>} />
      <div style={{ flex: 1, minHeight: 0, display: "flex" }}>
        <SplitList items={items} sel={sel} onSel={setSel} q={q} setQ={setQ} placeholder="Künstler filtern"
          render={(a) => <><ArtistArt hue={a.hue} size={32} name={a.name} /><ItemText a={a.name} /></>} />
        <div className="content detail" style={{ flex: 1, minWidth: 0 }} data-sw="NavigationSplitView · detail">
          <DetailHeader kind="Künstler" title={sel.name} art={<ArtistArt hue={sel.hue} size={132} name={sel.name} />}
            actions={<><Btn kind="prominent" lg icon="Play">Abspielen</Btn><Btn lg icon={following ? "Check" : "Plus"} onClick={() => setFollowing(!following)} sw="Button · .bordered (Toggle)">{following ? "Folge ich" : "Folgen"}</Btn></>}>
            {sel.tags.split(" · ").join(", ")}
          </DetailHeader>
          <SectHead title="Diskografie"><NSeg value={group} onChange={setGroup} options={[{ value: "album", label: "Alben" }, { value: "single", label: "Singles & EPs" }, { value: "compilation", label: "Compilations" }]} /></SectHead>
          <div style={{ padding: "0 28px", display: "grid", gridTemplateColumns: "repeat(auto-fill,minmax(150px,1fr))", gap: 18 }} data-sw="LazyVGrid">
            {disc.map((c) => <MediaCard key={c.id} c={c} sub={String(c.year)} />)}
          </div>
        </div>
      </div>
    </>
  );
};

Object.assign(window, { NFavorites, NPlaylists, NAlbums, NArtists });
