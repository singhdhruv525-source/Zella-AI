import { Icon } from "../BusinessUI";
import { sidebarMode, updateAppearance, useAppearance } from "../appearance";

// The arrow at the top of the sidebar (admin and CRM), next to the logo: folds the sidebar into a slim dock or opens
// it back up. Just the arrow; its name says what it does. The choice is saved with the person's appearance settings,
// so it is the same on every page and device, whichever theme they use. Placed by styles/brand.css.
export function DockToggle() {
  const look = useAppearance();
  const compact = sidebarMode(look) === "compact";
  const label = compact ? "Expand the sidebar" : "Shrink the sidebar to icons";
  return (
    <button type="button" className="zv-dock" aria-pressed={!compact} aria-label={label} title={label}
      onClick={() => updateAppearance({ sidebar: compact ? "full" : "compact" })}>
      <Icon name="chevron_left" size="sm" />
    </button>
  );
}
