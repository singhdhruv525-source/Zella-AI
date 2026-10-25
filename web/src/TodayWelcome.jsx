import "./TodayWelcome.css";

// The first thing someone sees after signing in. One quiet moment: the greeting settles in,
// the calming line arrives word by word, and a small line drawing of the time of day is traced.
const GLYPHS = {
  morning: (
    <>
      <path pathLength="1" d="M20 82 H100" />
      <path pathLength="1" d="M36 82 a24 24 0 0 1 48 0" />
      <path pathLength="1" d="M60 36 V46 M33 49 l7 7 M87 49 l-7 7 M18 72 h9 M93 72 h9" />
    </>
  ),
  afternoon: (
    <>
      <circle pathLength="1" cx="60" cy="60" r="20" />
      <path pathLength="1" d="M60 22 V32 M60 88 V98 M22 60 H32 M88 60 H98 M33 33 l7 7 M80 80 l7 7 M87 33 l-7 7 M40 80 l-7 7" />
    </>
  ),
  evening: (
    <>
      <path pathLength="1" d="M78 34 a28 28 0 1 0 14 46 a22 22 0 0 1 -14 -46 z" />
      <path pathLength="1" d="M34 34 v8 M30 38 h8 M92 96 v6 M89 99 h6" />
    </>
  ),
};

export default function TodayWelcome({ heading, business, owner, note, date, partOfDay }) {
  const words = String(note).split(" ");
  return (
    <section className="tw" aria-label="Welcome">
      <div className="tw-text">
        <h1 className="tw-heading">{heading}</h1>
        <p className="tw-business">{business}{owner ? ` · Owner: ${owner}` : ""}</p>
        <p className="tw-note" aria-label={note}>
          {words.map((word, i) => (
            <span key={i} aria-hidden="true" className="tw-word" style={{ "--i": i }}>{word}</span>
          ))}
        </p>
        <p className="tw-date">{date}</p>
      </div>
      <svg className="tw-glyph" viewBox="0 0 120 120" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
        {GLYPHS[partOfDay] ?? GLYPHS.afternoon}
      </svg>
    </section>
  );
}
