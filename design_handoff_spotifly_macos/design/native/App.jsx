const N_SCREENS = {
  home: { label: "Startseite", comp: NHome }, search: { label: "Suchen", comp: NSearchScreen }, queue: { label: "Warteschlange", comp: NQueue },
  speakers: { label: "Wiedergabe auf", comp: NSpeakers }, favorites: { label: "Favoriten", comp: NFavorites }, playlists: { label: "Playlists", comp: NPlaylists },
  albums: { label: "Alben", comp: NAlbums }, artists: { label: "Künstler", comp: NArtists }, profile: { label: "Profil", comp: NProfile },
};

const N_DEFAULTS = /*EDITMODE-BEGIN*/{
  "theme": "light",
  "accent": "#1DB954",
  "annotate": false
}/*EDITMODE-END*/;

const NativeApp = () => {
  const [t, setTweak] = useTweaks(N_DEFAULTS);
  const [screen, setScreen] = React.useState(() => localStorage.getItem("spf-native-screen") || "home");
  const [history, setHistory] = React.useState([]);
  const [playing, setPlaying] = React.useState(true);
  const [shuffle, setShuffle] = React.useState(false);
  const [repeat, setRepeat] = React.useState("off");
  const [queue, setQueue] = React.useState(QUEUE);
  const [currentIdx, setCurrentIdx] = React.useState(1);
  const [position, setPosition] = React.useState(NOW_PLAYING.position);
  const [volume, setVolume] = React.useState(70);
  const [sideHidden, setSideHidden] = React.useState(false);
  const [inspector, setInspector] = React.useState(false);
  const [settings, setSettings] = React.useState(false);

  React.useEffect(() => { document.documentElement.setAttribute("data-theme", t.theme); }, [t.theme]);
  React.useEffect(() => { document.documentElement.style.setProperty("--accent", t.accent); }, [t.accent]);
  React.useEffect(() => { document.body.classList.toggle("annot", !!t.annotate); }, [t.annotate]);
  React.useEffect(() => {
    const mv = (e) => { document.body.style.setProperty("--mx", e.clientX + "px"); document.body.style.setProperty("--my", e.clientY + "px"); };
    window.addEventListener("mousemove", mv); return () => window.removeEventListener("mousemove", mv);
  }, []);
  React.useEffect(() => { localStorage.setItem("spf-native-screen", screen); }, [screen]);

  React.useEffect(() => {
    if (!playing) return;
    const id = setInterval(() => setPosition((p) => {
      const dur = queue.find((q) => q.idx === currentIdx)?.duration ?? 200;
      if (p + 1 >= dur) { setCurrentIdx((i) => (i % queue.length) + 1); return 0; }
      return p + 1;
    }), 1000);
    return () => clearInterval(id);
  }, [playing, currentIdx, queue]);

  const track = React.useMemo(() => {
    const tk = queue.find((q) => q.idx === currentIdx) || queue[0];
    return { ...tk, album: tk.idx === 1 ? NOW_PLAYING.album : tk.title, position };
  }, [queue, currentIdx, position]);

  const nav = (s) => { if (s !== screen) { setHistory((h) => [...h, screen]); setScreen(s); } };
  const onJumpTo = (idx) => { setCurrentIdx(idx); setPosition(0); setPlaying(true); };
  const onToggleLike = (idx) => setQueue((q) => q.map((x) => (x.idx === (idx ?? currentIdx) ? { ...x, liked: !x.liked } : x)));
  const onPrev = () => { if (position > 4) setPosition(0); else { setCurrentIdx((i) => Math.max(1, i - 1)); setPosition(0); } };
  const onNext = () => { setCurrentIdx((i) => Math.min(queue.length, i + 1)); setPosition(0); };

  const tb = { sidebarHidden: sideHidden, onToggleSidebar: () => setSideHidden(false), canBack: history.length > 0 };
  const Screen = N_SCREENS[screen].comp;

  return (
    <div className="stage">
      <div className="win">
        <NSidebar current={screen} onNavigate={nav} queueCount={queue.length - currentIdx} hidden={sideHidden} onToggle={() => setSideHidden(true)} onSettings={() => setSettings(true)} />
        <main className="main">
          <Screen key={screen} tb={tb} tracks={screen === "favorites" ? FAVORITES : queue} currentIdx={currentIdx}
            onJumpTo={onJumpTo} onToggleLike={onToggleLike} onNavigate={nav} onSettings={() => setSettings(true)} />
          <NPlayer track={track} playing={playing} onTogglePlay={() => setPlaying((p) => !p)} onPrev={onPrev} onNext={onNext} onSeek={setPosition}
            onToggleLike={() => onToggleLike()} shuffle={shuffle} repeat={repeat} onToggleShuffle={() => setShuffle((s) => !s)}
            onCycleRepeat={() => setRepeat((r) => (r === "off" ? "all" : r === "all" ? "one" : "off"))}
            volume={volume} setVolume={setVolume} inspector={inspector} onToggleInspector={() => setInspector((v) => !v)} onDevices={() => nav("speakers")} />
        </main>
        {inspector && <NInspector track={track} queue={queue} currentIdx={currentIdx} onJumpTo={onJumpTo} />}
        {settings && <SettingsWindow onClose={() => setSettings(false)} />}
      </div>
      <TweaksPanel title="Tweaks">
        <TweakSection title="Ansicht">
          <TweakRadio label="Modus" value={t.theme} onChange={(v) => setTweak("theme", v)} options={[{ value: "light", label: "Hell" }, { value: "dark", label: "Dunkel" }]} />
          <TweakColor label="Akzent (AccentColor)" value={t.accent} onChange={(v) => setTweak("accent", v)} options={["#1DB954", "#007AFF", "#FF2D55", "#AF52DE"]} />
          <TweakToggle label="SwiftUI-Controls markieren" value={t.annotate} onChange={(v) => setTweak("annotate", v)} />
        </TweakSection>
        <TweakSection title="Navigation">
          <TweakSelect label="Screen" value={screen} onChange={nav} options={Object.entries(N_SCREENS).map(([k, v]) => ({ value: k, label: v.label }))} />
          <TweakButton onClick={() => setSettings(true)}>Einstellungen öffnen (⌘,)</TweakButton>
          <TweakButton onClick={() => setInspector((v) => !v)}>Jetzt läuft (Inspector)</TweakButton>
        </TweakSection>
      </TweaksPanel>
    </div>
  );
};

ReactDOM.createRoot(document.getElementById("root")).render(<NativeApp />);
