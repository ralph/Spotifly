// Shell — NavigationSplitView sidebar, toolbar, bottom player (safeAreaInset), Now-Playing inspector, Settings scene.

const NAV_MAIN = [
  { id: "home", label: "Startseite", icon: "Home" },
  { id: "search", label: "Suchen", icon: "Search" },
  { id: "queue", label: "Warteschlange", icon: "Queue", badge: true },
  { id: "speakers", label: "Wiedergabe auf", icon: "Speaker" },
];
const NAV_LIB = [
  { id: "favorites", label: "Favoriten", icon: "Heart" },
  { id: "playlists", label: "Playlists", icon: "Playlist" },
  { id: "albums", label: "Alben", icon: "Album" },
  { id: "artists", label: "Künstler", icon: "Artist" },
];

const NSidebar = ({ current, onNavigate, queueCount, hidden, onToggle, onSettings }) => {
  const Item = ({ it }) => {
    const I = Icons[it.icon];
    return (
      <button className={"side-i" + (current === it.id ? " on" : "")} onClick={() => onNavigate(it.id)}>
        <I size={15} /><span className="trunc">{it.label}</span>
        {it.badge && <span className="badge" data-sw=".badge(_:)">{queueCount}</span>}
      </button>
    );
  };
  return (
    <aside className={"side" + (hidden ? " hidden" : "")} data-sw="NavigationSplitView · List(.sidebar)">
      <div className="side-top">
        <div className="lights"><i></i><i></i><i></i></div>
        <button className="nb nb-borderless nb-icon" data-sw="ToolbarItem · SidebarToggle" onClick={onToggle}><Icons.Sidebar size={16} /></button>
      </div>
      <nav style={{ display: "flex", flexDirection: "column", gap: 1 }}>{NAV_MAIN.map((it) => <Item key={it.id} it={it} />)}</nav>
      <div className="side-h" data-sw="Section(header:)">Bibliothek</div>
      <nav style={{ display: "flex", flexDirection: "column", gap: 1 }}>{NAV_LIB.map((it) => <Item key={it.id} it={it} />)}</nav>
      <div className="side-foot" data-sw=".safeAreaInset(edge: .bottom)">
        <button className={"side-i" + (current === "profile" ? " on" : "")} style={{ height: 34, flex: 1 }} onClick={() => onNavigate("profile")}>
          <span style={{ width: 22, height: 22, borderRadius: "50%", background: "linear-gradient(135deg,#F4C57E,#E89A6E)", color: "#5C3B1E", fontSize: 10, fontWeight: 700, display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0 }} data-sw="AsyncImage">RJ</span>
          <span className="trunc">llralphj</span>
        </button>
        <button className="nb nb-borderless nb-icon" data-sw="SettingsLink" title="Einstellungen … (⌘,)" onClick={onSettings}><Icons.Settings size={15} /></button>
      </div>
    </aside>
  );
};

const NToolbar = ({ title, leading, trailing, sidebarHidden, onToggleSidebar, canBack }) => (
  <div className="tb" data-sw=".toolbar">
    {sidebarHidden && <><div className="lights" style={{ marginRight: 8 }}><i></i><i></i><i></i></div>
      <div className="glassgrp"><button className="tbi" onClick={onToggleSidebar} data-sw="SidebarToggle"><Icons.Sidebar size={15} /></button></div></>}
    <div className="glassgrp" data-sw="ControlGroup (Zurück/Vor)">
      <button className="tbi" disabled={!canBack}><Icons.ChevronLeft size={16} /></button><span className="div"></span>
      <button className="tbi" disabled><Icons.ChevronRight size={16} /></button>
    </div>
    <span className="tb-title" data-sw=".navigationTitle">{title}</span>
    {leading}
    <span className="tb-sp"></span>
    {trailing}
  </div>
);

const TbBtn = ({ icon, title, onClick, on }) => {
  const I = Icons[icon];
  return <div className="glassgrp"><button className="tbi" title={title} onClick={onClick} data-sw={"ToolbarItem · Button" + (on != null ? " (Toggle)" : "")} style={on ? { color: "var(--accent)" } : null}><I size={15} /></button></div>;
};

const NPlayer = ({ track, playing, onTogglePlay, onPrev, onNext, onSeek, onToggleLike, shuffle, repeat, onToggleShuffle, onCycleRepeat, volume, setVolume, inspector, onToggleInspector, onDevices }) => (
  <div className="player" data-sw=".safeAreaInset(edge: .bottom) · .glassEffect()">
    <div style={{ display: "flex", alignItems: "center", gap: 2 }}>
      <Btn kind="borderless" iconOnly icon="Shuffle" pressed={shuffle} onClick={onToggleShuffle} title="Zufällig" sw="Toggle · .button" />
      <Btn kind="borderless" iconOnly icon="Prev" onClick={onPrev} title="Zurück (⌘←)" />
      <button className="nb nb-borderless" data-sw="Button · .borderless" onClick={onTogglePlay} style={{ width: 38, height: 38, borderRadius: 19 }}>
        {playing ? <Icons.Pause size={22} /> : <Icons.Play size={22} />}
      </button>
      <Btn kind="borderless" iconOnly icon="Next" onClick={onNext} title="Weiter (⌘→)" />
      <button className="nb nb-borderless nb-icon" data-sw="Toggle · .button (3 Zustände)" onClick={onCycleRepeat} title="Wiederholen" style={{ position: "relative", color: repeat !== "off" ? "var(--accent)" : null }}>
        <Icons.Repeat size={15} />{repeat === "one" && <span style={{ position: "absolute", right: 3, bottom: 2, fontSize: 8, fontWeight: 800 }}>1</span>}
      </button>
    </div>
    <div style={{ flex: 1, minWidth: 0, display: "flex", alignItems: "center", gap: 10, padding: "0 10px" }}>
      <span data-sw="AsyncImage"><CoverArt hue={track.hue} pattern={track.pattern} size={40} rounded={6} /></span>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
          <div style={{ flex: 1, minWidth: 0, lineHeight: 1.25 }}>
            <div className="trunc t-head">{track.title}{track.subtitle ? ` – ${track.subtitle}` : ""}</div>
            <div className="trunc sec t-sub">{track.artist}</div>
          </div>
          <span className="sec t-cap mono tcap">{formatTime(track.position)} / {formatTime(track.duration)}</span>
        </div>
        <NSlider thin value={track.position} max={track.duration} onChange={onSeek} sw="Slider (Wiedergabeposition)" style={{ height: 10, marginTop: 2 }} />
      </div>
    </div>
    <div style={{ display: "flex", alignItems: "center", gap: 2 }}>
      <button className="nb nb-borderless nb-icon" data-sw="Button · .borderless (Toggle)" onClick={onToggleLike} title="Favorit" style={{ color: track.liked ? "var(--red)" : null }}>
        {track.liked ? <Icons.HeartFilled size={15} color="var(--red)" /> : <Icons.Heart size={15} />}
      </button>
      <NMenu items={trackMenu(track.liked)} sw="Menu" />
      <Btn kind="borderless" iconOnly icon="AirPlay" onClick={onDevices} title="Wiedergabe auf …" sw="Button → Wiedergabe auf" />
      <span className="vol"><Icons.Volume size={14} />
      <NSlider value={volume} onChange={setVolume} sw="Slider (Lautstärke)" style={{ width: 72 }} /></span>
      <Btn kind="borderless" iconOnly icon="Inspector" pressed={inspector} onClick={onToggleInspector} title="Jetzt läuft" sw="Toggle · .inspector(isPresented:)" />
    </div>
  </div>
);

const NInspector = ({ track, queue, currentIdx, onJumpTo }) => {
  const upNext = queue.filter((q) => q.idx > currentIdx).slice(0, 8);
  return (
    <aside className="inspector" data-sw=".inspector · Jetzt läuft">
      <div style={{ height: 52, display: "flex", alignItems: "center", padding: "0 16px" }}><span className="t-head">Jetzt läuft</span></div>
      <div style={{ padding: "0 20px 16px" }}>
        <span data-sw="AsyncImage"><CoverArt hue={track.hue} pattern={track.pattern} size={280} rounded={10} /></span>
        <div style={{ marginTop: 14 }}>
          <div className="t-title2 trunc">{track.title}</div>
          <div className="sec trunc">{track.subtitle ? track.subtitle + " · " : ""}{track.artist}</div>
          <div className="ter t-sub trunc" style={{ marginTop: 2 }}>{track.album}</div>
        </div>
      </div>
      <div style={{ borderTop: ".5px solid var(--sep)", flex: 1, minHeight: 0, display: "flex", flexDirection: "column" }}>
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", padding: "12px 16px 6px" }}>
          <span className="t-head">Als Nächstes</span><span className="sec t-sub">{queue.length - currentIdx} Titel</span>
        </div>
        <div style={{ overflow: "auto", padding: "0 8px 100px" }} data-sw="List">
          {upNext.map((t) => (
            <button key={t.idx} className="nli" onClick={() => onJumpTo(t.idx)}>
              <CoverArt hue={t.hue} pattern={t.pattern} size={32} rounded={4} />
              <div style={{ minWidth: 0, flex: 1, lineHeight: 1.25 }}><div className="trunc">{t.title}</div><div className="trunc sec t-sub">{t.artist}</div></div>
              <span className="sec t-sub mono">{formatTime(t.duration)}</span>
            </button>
          ))}
        </div>
      </div>
    </aside>
  );
};

const SettingsWindow = ({ onClose }) => {
  const [tab, setTab] = React.useState("playback");
  const [s, setS] = React.useState({ bitrate: "320", normalize: true, gapless: true, autoplay: true, launch: "home", dock: true, notify: true, cache: "5", theme: "system" });
  const set = (k) => (v) => setS({ ...s, [k]: v });
  const tabs = [{ id: "general", label: "Allgemein", icon: "Settings" }, { id: "playback", label: "Wiedergabe", icon: "Sliders" }, { id: "keys", label: "Kurzbefehle", icon: "Keyboard" }];
  return (
    <div className="swin" data-sw="Settings { TabView } — eigenes Fenster (⌘,)">
      <div style={{ position: "relative", padding: "12px 14px 4px", display: "flex", justifyContent: "center" }}>
        <div className="lights" style={{ position: "absolute", left: 14, top: 14 }}><i onClick={onClose} style={{ cursor: "pointer" }}></i><i></i><i style={{ opacity: .35 }}></i></div>
        <span className="t-head">{tabs.find((t) => t.id === tab).label}</span>
      </div>
      <div className="stabs" data-sw="TabView · Toolbar-Tabs">
        {tabs.map((t) => { const I = Icons[t.icon]; return <button key={t.id} className={"stab" + (tab === t.id ? " on" : "")} onClick={() => setTab(t.id)}><I size={20} />{t.label}</button>; })}
      </div>
      <div style={{ overflow: "auto", borderTop: ".5px solid var(--sep)", paddingTop: 16 }} data-sw="Form · .formStyle(.grouped)">
        {tab === "general" && <div className="nform">
          <NSection header="App">
            <NRow label="Beim Start öffnen"><NPopup value={s.launch} onChange={set("launch")} options={[{ value: "home", label: "Startseite" }, { value: "queue", label: "Warteschlange" }, { value: "last", label: "Zuletzt geöffnet" }]} /></NRow>
            <NRow label="Erscheinungsbild"><NSeg value={s.theme} onChange={set("theme")} options={[{ value: "system", label: "System" }, { value: "light", label: "Hell" }, { value: "dark", label: "Dunkel" }]} /></NRow>
            <NRow label="Im Dock anzeigen" sub="Aus: nur in der Menüleiste."><NToggle on={s.dock} onChange={set("dock")} /></NRow>
            <NRow label="Mitteilung bei Titelwechsel"><NToggle on={s.notify} onChange={set("notify")} /></NRow>
          </NSection>
          <NSection header="Offline-Cache" footer="Bereits geladene Titel starten ohne Puffern. Markiert mit „C“ in der Warteschlange.">
            <NRow label="Maximale Größe"><NPopup value={s.cache} onChange={set("cache")} options={[{ value: "1", label: "1 GB" }, { value: "5", label: "5 GB" }, { value: "10", label: "10 GB" }, { value: "0", label: "Unbegrenzt" }]} /></NRow>
            <NRow label="Belegt">2,1 GB<Btn>Leeren …</Btn></NRow>
          </NSection>
        </div>}
        {tab === "playback" && <div className="nform">
          <NSection header="Audio" footer="Spotifly streamt über Librespot. Die Bitrate gilt für neu geladene Titel.">
            <NRow label="Streaming-Qualität"><NPopup value={s.bitrate} onChange={set("bitrate")} options={[{ value: "96", label: "Normal (96 kbit/s)" }, { value: "160", label: "Hoch (160 kbit/s)" }, { value: "320", label: "Sehr hoch (320 kbit/s)" }]} /></NRow>
            <NRow label="Lautstärke angleichen" sub="Nutzt die Normalisierungsdaten von Spotify."><NToggle on={s.normalize} onChange={set("normalize")} /></NRow>
            <NRow label="Lückenlose Wiedergabe"><NToggle on={s.gapless} onChange={set("gapless")} /></NRow>
          </NSection>
          <NSection header="Autoplay" footer="Spielt ähnliche Titel, wenn die Warteschlange endet.">
            <NRow label="Autoplay"><NToggle on={s.autoplay} onChange={set("autoplay")} /></NRow>
          </NSection>
        </div>}
        {tab === "keys" && <div className="nform">
          <NSection header="Wiedergabe" footer="Medientasten der Tastatur und das Kontrollzentrum funktionieren zusätzlich (MPRemoteCommandCenter).">
            {[["Wiedergabe / Pause", "Leertaste"], ["Nächster Titel", "⌘ →"], ["Vorheriger Titel", "⌘ ←"], ["Lauter / Leiser", "⌘ ↑ / ⌘ ↓"], ["Favorit umschalten", "⌘ L"]].map(([l, k]) => <NRow key={l} label={l} sw="LabeledContent · .keyboardShortcut"><span className="kbd">{k}</span></NRow>)}
          </NSection>
          <NSection header="Navigation">
            {[["Suchen", "⌘ F"], ["Seitenleiste ein/aus", "⌃ ⌘ S"], ["Jetzt läuft ein/aus", "⌥ ⌘ I"], ["Einstellungen", "⌘ ,"]].map(([l, k]) => <NRow key={l} label={l} sw="LabeledContent · .keyboardShortcut"><span className="kbd">{k}</span></NRow>)}
          </NSection>
        </div>}
        <div style={{ textAlign: "center", padding: "0 0 18px" }} className="ter t-sub">Spotifly 2.4.1 (7245) · Librespot 0.6.0</div>
      </div>
    </div>
  );
};

Object.assign(window, { NSidebar, NToolbar, TbBtn, NPlayer, NInspector, SettingsWindow });
