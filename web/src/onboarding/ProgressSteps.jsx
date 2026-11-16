// A progress bar for a journey of numbered screens: "Step 3 of 7", the screen's name, a bar, and a dot per screen
// (done, here, to come). The words carry the meaning; the bar and dots only back them up. Reusable: give it the
// screens and the index of the one on show.
//   screens   [{ key, label }]
//   current   index of the screen on show (0 based)
export default function ProgressSteps({ screens, current, label = "Your setup" }) {
  const total = screens.length;
  const at = Math.min(Math.max(0, current), total - 1);
  const percent = total > 1 ? Math.round((at / (total - 1)) * 100) : 100;
  return (
    <div className="zv-progress">
      <div className="zv-progress-text">
        <span className="zv-progress-count">Step {at + 1} of {total}</span>
        <span className="zv-progress-name">{screens[at]?.label}</span>
      </div>
      <div className="zv-progress-bar" role="progressbar" aria-label={label} aria-valuemin={1} aria-valuemax={total} aria-valuenow={at + 1}
        aria-valuetext={`Step ${at + 1} of ${total}: ${screens[at]?.label ?? ""}`}>
        <span style={{ width: `${percent}%` }} />
      </div>
      <ol className="zv-progress-dots" aria-hidden="true">
        {screens.map((s, i) => <li key={s.key} className={i < at ? "done" : i === at ? "here" : ""} title={s.label} />)}
      </ol>
    </div>
  );
}
