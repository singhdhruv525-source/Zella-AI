// A progress bar for a journey of numbered screens: "Step 3 of 7" and one segment per screen (done and current
// filled). The words carry the meaning; the segments only back them up. Reusable: give it the screens and the index of
// the one on show.
//   screens   [{ key, label }]
//   current   index of the screen on show (0 based)
export default function ProgressSteps({ screens, current, label = "Your setup" }) {
  const total = screens.length;
  const at = Math.min(Math.max(0, current), total - 1);
  return (
    <div className="zv-progress">
      <span className="zv-progress-count">Step {at + 1} of {total}</span>
      <div className="zv-progress-segments" role="progressbar" aria-label={label} aria-valuemin={1} aria-valuemax={total} aria-valuenow={at + 1}
        aria-valuetext={`Step ${at + 1} of ${total}: ${screens[at]?.label ?? ""}`}>
        {screens.map((s, i) => <span key={s.key} className={i < at ? "done" : i === at ? "here" : ""} />)}
      </div>
    </div>
  );
}
