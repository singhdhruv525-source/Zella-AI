import { useCallback, useEffect, useLayoutEffect, useMemo, useReducer, useRef, useState } from "react";
import { loadVoiceSample } from "./voiceApi";
import { canSample, cardLook, carouselItems, dotsModel, nearestIndex, providerName, providerOf, providersPresent, selectedAnnouncement, voiceTraits } from "./voiceChoices";
import { answerToAction, buttonFor, initialPlayback, playbackReducer } from "./voicePlayback";

// The voice picker both Settings > Voice and the admin create business wizard use: a carousel of voice cards. The
// centred card is the choice: swiping, the arrows, the dots or the arrow keys move it, and moving selects (onChange
// gets { target: { value } }, like the select it replaced; "" is Zella Voice's default). Zella Voice's default comes
// first, then Cartesia, ElevenLabs and Vapi, voices in the business's languages first. Cards grow, brighten and take
// the accent glow as they reach the middle, following the scroll itself (transform and opacity only); with reduced
// motion everything moves at once. A Cartesia or ElevenLabs card has a play button (the voice-sample function); it
// never selects, and one sample plays at a time across the page. Disabled: the chosen voice only, nothing moves.

// One audio element for the page, so starting a sample anywhere stops the one playing
let sharedAudio = null, audioOwner = null;
function takeAudio(owner) {
  if (audioOwner && audioOwner !== owner) audioOwner.stopped();
  audioOwner = owner;
  if (!sharedAudio) sharedAudio = new Audio();
  sharedAudio.onplaying = sharedAudio.onended = sharedAudio.onerror = null;
  return sharedAudio;
}
function releaseAudio(owner) {
  if (audioOwner !== owner || !sharedAudio) return;
  sharedAudio.onplaying = sharedAudio.onended = sharedAudio.onerror = null;
  sharedAudio.pause();
  sharedAudio.removeAttribute("src");
  audioOwner = null;
}

const reducedMotion = () => typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;

function PlayIcon({ mode }) {
  if (mode === "loading") return <span className="zs-vc-spin" aria-hidden="true" />;
  return (
    <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true" focusable="false">
      {mode === "stop" ? <rect x="7" y="7" width="10" height="10" rx="1.5" fill="currentColor" /> : <path d="M8 5.5v13l10.5-6.5z" fill="currentColor" />}
    </svg>
  );
}
const Chevron = ({ left }) => (
  <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true" focusable="false">
    <path d={left ? "M14.5 6 8.5 12l6 6" : "M9.5 6l6 6-6 6"} fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
  </svg>
);

function CardBody({ item, defaultName, checked, note }) {
  return (
    <>
      {checked && <span className="zs-vc-check" aria-hidden="true">✓</span>}
      {item.isDefault ? (
        <>
          <span className="zs-pill accent">Default</span>
          <strong className="zs-vc-name">Zella Voice default</strong>
          <span className="zs-vc-traits">{defaultName ? `Uses ${defaultName}` : "Chosen by Zella Voice"}</span>
        </>
      ) : item.missing ? (
        <>
          <strong className="zs-vc-name">Saved voice</strong>
          <span className="zs-vc-traits">No longer on the approved list</span>
        </>
      ) : (
        <>
          <span className={`zs-pill zs-vc-provider p-${providerOf(item)}`}>{providerName(providerOf(item))}</span>
          <strong className="zs-vc-name">{item.name ?? item.id}</strong>
          {voiceTraits(item) && <span className="zs-vc-traits">{voiceTraits(item)}</span>}
        </>
      )}
      {note && <small className="zs-vc-note">{note}</small>}
    </>
  );
}

export function VoiceSelect({ value, onChange, choices, languages, defaultName, defaultId, disabled, labelledBy }) {
  const current = value ?? "";
  const [provider, setProvider] = useState("all");
  const providers = useMemo(() => providersPresent(choices), [choices]);
  const items = useMemo(() => carouselItems(choices, languages, provider), [choices, languages, provider]);
  const selectedIndex = items.findIndex((i) => i.id === current);
  const [centre, setCentre] = useState(Math.max(0, selectedIndex));
  const [playback, dispatch] = useReducer(playbackReducer, initialPlayback);
  const track = useRef(null);
  const slides = useRef([]);
  const target = useRef(null);      // the card a scroll we started is heading to
  const touched = useRef(false);    // the person is swiping, dragging or wheeling the track (only that selects on rest)
  const frame = useRef(0);
  const token = useRef(0);
  const owner = useRef({ stopped: () => dispatch({ type: "stop" }) });
  const centreRef = useRef(centre);
  centreRef.current = centre;
  const choiceById = useCallback((id) => (choices ?? []).find((c) => c.id === id), [choices]);
  const defaultChoice = choiceById(defaultId);
  const sampleOf = (item) => (item.isDefault ? defaultChoice : item);

  const select = useCallback((i) => {
    const item = items[i];
    if (!item || disabled || item.id === current) return;
    onChange?.({ target: { value: item.id } });
  }, [items, disabled, current, onChange]);

  // each card's scale, opacity and glow from its distance to the middle of the track
  const paint = useCallback(() => {
    frame.current = 0;
    const t = track.current;
    if (!t) return;
    const mid = t.scrollLeft + t.clientWidth / 2;
    const els = slides.current.slice(0, items.length);
    const step = els[1] ? els[1].offsetLeft - els[0].offsetLeft : (els[0]?.offsetWidth || 1);
    const centres = els.map((el) => (el ? el.offsetLeft + el.offsetWidth / 2 : Infinity));
    const still = reducedMotion();
    const near = nearestIndex(centres, mid);
    els.forEach((el, i) => {
      if (!el) return;
      const d = still ? (i === near ? 0 : Math.sign(i - near)) : (centres[i] - mid) / step;
      const look = cardLook(d);
      // shrink towards the middle, so a neighbour keeps its inner edge and peeks in from the side
      const shift = -Math.sign(d) * (1 - look.scale) * el.offsetWidth / 2;
      el.style.transform = `translateX(${shift.toFixed(1)}px) scale(${look.scale})`;
      el.style.opacity = String(look.opacity);
      const glow = el.querySelector(".zs-vc-glow");
      if (glow) glow.style.opacity = String(look.glow);
    });
    if (near >= 0 && near !== centreRef.current) setCentre(near);
  }, [items.length]);
  const schedule = useCallback(() => { if (!frame.current) frame.current = requestAnimationFrame(paint); }, [paint]);

  const scrollToIndex = useCallback((i, smooth) => {
    const t = track.current, el = slides.current[i];
    if (!t || !el) return;
    target.current = i;
    t.scrollTo({ left: el.offsetLeft + el.offsetWidth / 2 - t.clientWidth / 2, behavior: smooth && !reducedMotion() ? "smooth" : "auto" });
    schedule();
  }, [schedule]);

  const goTo = useCallback((i, focus) => {
    if (disabled) return;
    const n = Math.min(Math.max(0, i), items.length - 1);
    setCentre(n);
    scrollToIndex(n, true);
    select(n);
    if (focus) slides.current[n]?.querySelector('[role="radio"]')?.focus({ preventScroll: true });
  }, [disabled, items.length, scrollToIndex, select]);

  // the chosen voice in the middle when the page opens, the filter changes or the value changes from outside;
  // a choice the filter hides leaves the default in the middle without choosing it
  useLayoutEffect(() => {
    if (disabled) return;
    const i = selectedIndex >= 0 ? selectedIndex : 0;
    setCentre(i);
    scrollToIndex(i, false);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [current, provider, items.length, disabled]);

  // a swipe or drag that comes to rest chooses the card in the middle (a scroll we started has already chosen)
  useEffect(() => {
    const t = track.current;
    if (!t || disabled) return;
    let idle = 0;
    const settle = () => {
      clearTimeout(idle);
      const els = slides.current.slice(0, items.length);
      const near = nearestIndex(els.map((el) => (el ? el.offsetLeft + el.offsetWidth / 2 : Infinity)), t.scrollLeft + t.clientWidth / 2);
      const ours = target.current, theirs = touched.current;
      target.current = null;
      touched.current = false;
      // only a swipe, drag or wheel selects; a scroll from focus moving (Tab) or from us never does
      if (theirs && near >= 0 && near !== ours) select(near);
    };
    const onScroll = () => { schedule(); clearTimeout(idle); idle = setTimeout(settle, 160); };
    const hasEnd = "onscrollend" in window;
    const onTouch = () => { touched.current = true; };
    const onKeyAnywhere = (e) => { if (e.key === "Tab") touched.current = false; };   // focus moving is never a swipe
    document.addEventListener("keydown", onKeyAnywhere, true);
    const inputs = ["pointerdown", "touchstart", "wheel"];
    for (const ev of inputs) t.addEventListener(ev, onTouch, { passive: true });
    t.addEventListener("scroll", onScroll, { passive: true });
    if (hasEnd) t.addEventListener("scrollend", settle);
    const onResize = () => { scrollToIndex(centreRef.current, false); };
    window.addEventListener("resize", onResize);
    return () => { document.removeEventListener("keydown", onKeyAnywhere, true); for (const ev of inputs) t.removeEventListener(ev, onTouch); t.removeEventListener("scroll", onScroll); if (hasEnd) t.removeEventListener("scrollend", settle); window.removeEventListener("resize", onResize); clearTimeout(idle); };
  }, [disabled, items.length, select, schedule, scrollToIndex]);

  useEffect(() => () => { cancelAnimationFrame(frame.current); releaseAudio(owner.current); }, []);

  async function play(item) {
    const choice = sampleOf(item);
    if (!choice) return;
    const key = item.id;
    const wasMine = playback.voiceId === key && playback.status !== "idle";
    const mine = ++token.current;
    releaseAudio(owner.current);
    dispatch({ type: "press", voiceId: key });
    if (wasMine) return;
    let data = null, error = null;
    try { ({ data, error } = await loadVoiceSample(choice.id)); } catch (e) { error = e; }
    if (mine !== token.current) return;   // pressed again, or another card, meanwhile
    const action = answerToAction(key, data, error);
    if (action.type === "failed") { dispatch(action); return; }
    const audio = takeAudio(owner.current);
    audio.onplaying = () => mine === token.current && dispatch({ type: "playing", voiceId: key });
    audio.onended = () => dispatch({ type: "ended", voiceId: key });
    audio.onerror = () => dispatch({ type: "failed", voiceId: key, kind: "try_again" });
    audio.src = action.url;
    audio.play().catch(() => mine === token.current && dispatch({ type: "failed", voiceId: key, kind: "try_again" }));
  }

  function onKey(e) {
    const moves = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 };
    if (e.key in moves) { e.preventDefault(); goTo(centre + moves[e.key], true); }
    else if (e.key === "Home") { e.preventDefault(); goTo(0, true); }
    else if (e.key === "End") { e.preventDefault(); goTo(items.length - 1, true); }
    else if (e.key === " ") { e.preventDefault(); const i = Number(e.currentTarget.dataset.index); goTo(Number.isInteger(i) ? i : centre, true); }
  }

  const playButton = (item, i) => {
    const choice = sampleOf(item);
    if (!canSample(choice)) return null;
    const b = buttonFor(playback, item.id, item.isDefault ? `the Zella Voice default, ${choice.name ?? choice.id}` : choice.name ?? choice.id);
    return (
      <button type="button" className={`zs-vc-play ${b.mode}`} aria-label={b.label} tabIndex={i === undefined || i === centre ? 0 : -1} aria-pressed={b.mode !== "play"} title={b.label}
        onClick={(e) => { e.stopPropagation(); play(item); }} onKeyDown={(e) => e.stopPropagation()}>
        <PlayIcon mode={b.mode} />
      </button>
    );
  };
  const noteFor = (item) => (canSample(sampleOf(item)) ? buttonFor(playback, item.id, "").note : null);
  const announced = selectedAnnouncement(current ? choiceById(current) : null, defaultName);

  if (disabled) {
    const item = selectedIndex >= 0 ? items[selectedIndex] : current ? choiceById(current) ?? { id: current, missing: true } : items[0];
    return (
      <div className="zs zs-vc is-disabled">
        <div className="zs-vc-stage">
          <div className="zs-vc-track" role="radiogroup" aria-labelledby={labelledBy} aria-label={labelledBy ? undefined : "Voice"} aria-disabled="true">
            <div className="zs-vc-slide is-centre">
              <div role="radio" aria-checked="true" aria-disabled="true" tabIndex={0} className="zs-vc-card">
                <span className="zs-vc-glow" aria-hidden="true" />
                <CardBody item={item} defaultName={defaultName} checked note={noteFor(item)} />
              </div>
              {playButton(item)}
            </div>
          </div>
        </div>
      </div>
    );
  }

  const dots = dotsModel(items.length, centre);
  return (
    <div className="zs zs-vc">
      {providers.length > 1 && (
        <div className="zs-vc-chips" role="group" aria-label="Show voices from">
          {[{ provider: "all", name: "All" }, ...providers].map((p) => (
            <button key={p.provider} type="button" className={`zs-chip ${provider === p.provider ? "on" : ""}`} aria-pressed={provider === p.provider}
              onClick={() => setProvider(p.provider)}>{p.name}</button>
          ))}
        </div>
      )}
      <div className="zs-vc-stage">
        <div className="zs-vc-track" ref={track} role="radiogroup" aria-labelledby={labelledBy} aria-label={labelledBy ? undefined : "Voice"}>
          {items.map((item, i) => {
            const checked = item.id === current;
            return (
              <div key={item.id || "default"} className={`zs-vc-slide ${i === centre ? "is-centre" : ""}`} ref={(el) => { slides.current[i] = el; }}>
                <div role="radio" aria-checked={checked} tabIndex={i === centre ? 0 : -1} className="zs-vc-card" onKeyDown={onKey} data-index={i}
                  onClick={() => goTo(i, i !== centre)}>
                  <span className="zs-vc-glow" aria-hidden="true" />
                  <CardBody item={item} defaultName={defaultName} checked={checked} note={noteFor(item)} />
                </div>
                {playButton(item, i)}
              </div>
            );
          })}
        </div>
      </div>
      <div className="zs-vc-foot">
        <button type="button" className="zs-vc-arrow prev" aria-label="Previous voice" disabled={centre <= 0} onClick={() => goTo(centre - 1)}><Chevron left /></button>
        <div className="zs-vc-dots">
          {dots.dots.map((i) => (
            <button key={i} type="button" tabIndex={-1} className={`zs-vc-dot ${i === centre ? "on" : ""}`} aria-current={i === centre ? "true" : undefined}
              aria-label={items[i].isDefault ? "Zella Voice default" : items[i].name ?? items[i].id} onClick={() => goTo(i)} />
          ))}
        </div>
        {dots.counter && <span className="zs-vc-counter">{dots.counter}</span>}
        <button type="button" className="zs-vc-arrow next" aria-label="Next voice" disabled={centre >= items.length - 1} onClick={() => goTo(centre + 1)}><Chevron /></button>
      </div>
      <p className="zs-sr-only" aria-live="polite">{announced}</p>
    </div>
  );
}
